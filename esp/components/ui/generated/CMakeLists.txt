SET(SOURCES screens/ui_test.c
    ui.c
    components/ui_comp_hook.c
    ui_helpers.c
    fonts/ui_font_Font40.c)

add_library(ui ${SOURCES})
