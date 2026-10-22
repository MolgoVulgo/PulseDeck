# test_001: isolated experimental SVG test on SquareLine ui_test.
# Build C arrays from the ORIGINAL SVG sources; never edit generated/ or SVG files.
set(_svg_icon_root "${CMAKE_CURRENT_LIST_DIR}/../ui/assets/icone_weather")
set(_svg_test_source "${CMAKE_CURRENT_BINARY_DIR}/svg_test_assets.c")
set(_svg_test_content "#include <stdint.h>\n")

foreach(_svg_icon IN ITEMS clear-day fog rain)
    set(_svg_input "${_svg_icon_root}/${_svg_icon}.svg")
    if(NOT EXISTS "${_svg_input}")
        message(FATAL_ERROR "test_001 requires original SVG: ${_svg_input}")
    endif()
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_svg_input}")
    file(READ "${_svg_input}" _svg_hex HEX)
    string(LENGTH "${_svg_hex}" _svg_hex_chars)
    math(EXPR _svg_len "${_svg_hex_chars} / 2")
    # Exact bytes, plus one NUL terminator, in flash. No SVG rewriting or rasterization.
    string(REGEX REPLACE "(..)" "0x\\1, " _svg_bytes "${_svg_hex}")
    string(REPLACE "-" "_" _svg_symbol "${_svg_icon}")
    string(APPEND _svg_test_content
        "const uint8_t pd_svg_${_svg_symbol}[] = { ${_svg_bytes}0x00 };\n"
        "const uint32_t pd_svg_${_svg_symbol}_len = ${_svg_len}u;\n")
endforeach()
file(WRITE "${_svg_test_source}" "${_svg_test_content}")

# test_002: embed the local original Meteocons Lottie JSON at configure time.
# Generated C stays in the build directory; no network access is required.
find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(_lottie_source "${CMAKE_CURRENT_LIST_DIR}/../ui/assets/meteocons/fill/clear-day.json")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${_lottie_source}" "${CMAKE_CURRENT_LIST_DIR}/lottie_assets/fetch_clear_day.py")
set(_lottie_build_dir "${CMAKE_CURRENT_BINARY_DIR}/meteocons_lottie")
set(_lottie_c_source "${_lottie_build_dir}/clear_day_json.c")
execute_process(
    COMMAND "${Python3_EXECUTABLE}"
        "${CMAKE_CURRENT_LIST_DIR}/lottie_assets/fetch_clear_day.py"
        --source "${_lottie_source}"
        --out-c "${_lottie_c_source}"
    RESULT_VARIABLE _meteocons_result
    OUTPUT_VARIABLE _meteocons_output
    ERROR_VARIABLE _meteocons_error
)
if(NOT _meteocons_result EQUAL 0 OR NOT EXISTS "${_lottie_c_source}")
    message(FATAL_ERROR "Meteocons Lottie setup failed: ${_meteocons_error} ${_meteocons_output}")
endif()
message(STATUS "${_meteocons_output}")

idf_component_register(
    SRCS "main.c" "display.c" "touch.c" "lvgl_port.c"
         "diagnostics.c" "rgb_test.c" "svg_test.c" "${_svg_test_source}" "${_lottie_c_source}"
    INCLUDE_DIRS "."
    REQUIRES esp_timer esp_system esp_lcd esp_driver_gpio esp_driver_i2c esp_psram esp_mm
    PRIV_REQUIRES ui esp_rom esp_wifi esp_driver_tsens
)
# esp32_metrics.c intentionally excluded: generated export currently only defines ui_test.
