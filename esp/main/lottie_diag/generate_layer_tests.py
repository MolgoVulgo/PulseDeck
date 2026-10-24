#!/usr/bin/env python3
"""Generate Lottie layer-isolation fixtures in CMake build, leaving Meteocons untouched.

A/B names refer to Lottie JSON layers[0]/layers[1], not presumed visual roles.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path

EXPECTED_ORIGINAL_SHA = '930084453639864f519a4e2d2b791b042ac94b67816614144ff28e471106fc24'


def b_reduce_shapes(layer):
    """Diagnostic simplification: remove graphical detail while preserving Lottie shape structure.

    Progressively narrow first group's nested contents and preserve its last transform
    (if any) and one paint. If this leaves identical JSON, fall back to a geometry-only
    layer (empty shapes). Empty output is useful solely to separate painting/geometry
    from the loader; it is NOT a visual test.
    """
    if not isinstance(layer.get('shapes'), list):
        raise ValueError('layer B lacks shapes array')
    shapes = layer['shapes']
    original = copy.deepcopy(shapes)
    if not shapes:
        raise ValueError('layer B has no shapes to simplify')
    layer['shapes'] = [copy.deepcopy(shapes[0])]
    head = layer['shapes'][0]
    if head.get('ty') == 'gr' and isinstance(head.get('it'), list):
        parts = head['it']
        geometry = next((x for x in parts if x.get('ty') in ('sh', 'el', 'rc', 'sr')), None)
        paint = next((x for x in parts if x.get('ty') in ('fl', 'st', 'gf', 'gs')), None)
        transform = next((x for x in reversed(parts) if x.get('ty') == 'tr'), None)
        if geometry is not None:
            items = [copy.deepcopy(geometry)]
            if paint is not None: items.append(copy.deepcopy(paint))
            if transform is not None: items.append(copy.deepcopy(transform))
            head['it'] = items
    if layer['shapes'] == original:
        # A diagnostic that paints nothing, to isolate failures from geometric content.
        # Explicitly report blank rendering in the manifest.
        layer['shapes'] = []
        return 'no_shapes'
    return 'simplified_shapes'


def create(raw):
    if hashlib.sha256(raw).hexdigest() != EXPECTED_ORIGINAL_SHA:
        raise ValueError('original Meteocons SHA mismatch: refuse unexpected asset')
    source = json.loads(raw.decode('utf-8'))
    layers = source.get('layers')
    if not isinstance(layers, list) or len(layers) != 2:
        raise ValueError(f'expected exactly 2 Lottie layers, found {len(layers) if isinstance(layers,list) else "none"}')
    for name in ('fr', 'ip', 'op', 'w', 'h'):
        if name not in source: raise ValueError('missing Lottie attribute ' + name)
    output = {}
    for name, selected in [('a', [layers[0]]), ('b', [layers[1]]), ('reverse', [layers[1], layers[0]])]:
        obj = copy.deepcopy(source)
        obj['layers'] = copy.deepcopy(selected)
        obj['nm'] = 'PulseDeck diagnostic ' + name
        output[name] = json.dumps(obj, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    reduced = copy.deepcopy(source)
    reduced['layers'] = [copy.deepcopy(layers[1])]
    reduced['nm'] = 'PulseDeck diagnostic B simplified'
    reduction = b_reduce_shapes(reduced['layers'][0])
    output['b_reduced'] = json.dumps(reduced, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    if output['b_reduced'] == output['b']:
        raise ValueError('B reduced unexpectedly identical to B')
    return output, source, reduction


def generate_c(variants, source, reduction):
    result = [
        '/* GENERATED only under CMake build; source: Meteocons clear-day Fill (MIT). */',
        '#include <stdint.h>',
        f'const uint32_t pd_layer_frames = {int(round(source["op"] - source["ip"]))}u;',
        f'const uint32_t pd_layer_fps_milli = {int(round(source["fr"]*1000))}u;',
    ]
    for name, raw in variants.items():
        tag = 'pd_layer_' + name
        data = raw + b'\0'
        result.append('const uint8_t ' + tag + '_json[] = {')
        for start in range(0, len(data), 24):
            result.append('    ' + ', '.join('0x%02x' % x for x in data[start:start+24]) + ',')
        result += ['};', f'const uint32_t {tag}_len = {len(raw)}u;',
                   f'/* {name} sha256={hashlib.sha256(raw).hexdigest()} bytes={len(raw)} */']
    result.append(f'/* B reduction type: {reduction} */')
    return ('\n'.join(result) + '\n').encode('utf-8')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--out-c', type=Path, required=True)
    args = ap.parse_args()
    output, source, reduction = create(args.source.read_bytes())
    text = generate_c(output, source, reduction)
    args.out_c.parent.mkdir(parents=True, exist_ok=True)
    if not args.out_c.exists() or args.out_c.read_bytes() != text:
        args.out_c.write_bytes(text)
    print(f'PD_LAYER_TEST source_sha={EXPECTED_ORIGINAL_SHA} total_layers=2 frames={source["op"]-source["ip"]} fps={source["fr"]} B_reduction={reduction}')
    for name, raw in output.items():
        print(f'  variant={name} bytes={len(raw)} sha256={hashlib.sha256(raw).hexdigest()}')


if __name__ == '__main__':
    main()
