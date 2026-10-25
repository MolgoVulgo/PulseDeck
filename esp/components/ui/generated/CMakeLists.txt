SET(SOURCES components/ui_comp_container1.c
    components/ui_comp.c
    screens/ui_clock.c
    screens/ui_meteo.c
    screens/ui_esp32.c
    screens/ui_monitoring.c
    ui.c
    components/ui_comp_hook.c
    ui_helpers.c
    images/ui_img_location_png.c
    images/ui_img_icone_weather_barometer_svg.c
    fonts/ui_font_Font40.c)

add_library(ui ${SOURCES})
