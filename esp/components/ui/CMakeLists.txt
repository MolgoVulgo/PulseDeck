# Component ESP-IDF maintenu a la main. Ne PAS utiliser le CMakeLists
# genere par SquareLine dans generated/ (celui-ci est ecrase a chaque export).
set(_squareline_root "${CMAKE_CURRENT_LIST_DIR}/generated")
set(_squareline_list "${_squareline_root}/filelist.txt")

if(NOT EXISTS "${_squareline_list}")
    message(FATAL_ERROR "SquareLine filelist.txt absent: ${_squareline_list}; re-exporter l'UI")
endif()

# Le fichier d'export est la source de verite pour les .c generes.
# Sa modification doit provoquer une reconfiguration CMake.
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_squareline_list}")
file(STRINGS "${_squareline_list}" _squareline_entries)
set(_squareline_sources "")
foreach(_entry IN LISTS _squareline_entries)
    string(STRIP "${_entry}" _entry)
    if(_entry STREQUAL "")
        continue()
    endif()
    if(NOT _entry MATCHES "^[A-Za-z0-9_./-]+[.]c$" OR _entry MATCHES "[.][.]")
        message(FATAL_ERROR "Chemin SquareLine non autorise dans filelist.txt: ${_entry}")
    endif()
    if(NOT EXISTS "${_squareline_root}/${_entry}")
        message(FATAL_ERROR "Source SquareLine absente: ${_squareline_root}/${_entry}")
    endif()
    list(APPEND _squareline_sources "generated/${_entry}")
endforeach()
if(NOT _squareline_sources)
    message(FATAL_ERROR "Aucune source C dans l'export SquareLine")
endif()

idf_component_register(
    SRCS ${_squareline_sources}
    INCLUDE_DIRS "generated"
    REQUIRES lvgl__lvgl
)
