import unittest

from pulsedeck_agent.collectors.network import CounterSample, rates_from_samples


class NetworkRateTests(unittest.TestCase):
    def test_first_sample_is_invalid(self) -> None:
        rx, tx = rates_from_samples(None, CounterSample(10.0, 100, 200), source="test")
        self.assertFalse(rx.valid)
        self.assertFalse(tx.valid)
        self.assertEqual(rx.read_error, "warmup_required")

    def test_rate_is_delta_over_elapsed(self) -> None:
        previous = CounterSample(10.0, 1000, 2000)
        current = CounterSample(12.0, 3000, 5000)
        rx, tx = rates_from_samples(previous, current, source="test")
        self.assertEqual(rx.raw_value, 1000.0)
        self.assertEqual(tx.raw_value, 1500.0)

    def test_counter_reset_is_invalid(self) -> None:
        previous = CounterSample(10.0, 1000, 2000)
        current = CounterSample(12.0, 900, 2100)
        rx, tx = rates_from_samples(previous, current, source="test")
        self.assertFalse(rx.valid)
        self.assertFalse(tx.valid)
        self.assertEqual(rx.read_error, "counter_reset")


if __name__ == "__main__":
    unittest.main()
