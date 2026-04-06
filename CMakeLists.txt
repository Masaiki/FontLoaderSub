cmake_minimum_required(VERSION 3.15)
project(FontLoaderSub C OBJC)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# --------------------------------------------------------------------------
# Source files common to all platforms
# --------------------------------------------------------------------------
set(COMMON_SOURCES
    FontLoaderSub/ass_parser.c
    FontLoaderSub/ass_string.c
    FontLoaderSub/cstl.c
    FontLoaderSub/font_loader.c
    FontLoaderSub/font_set.c
    FontLoaderSub/tim_sort.c
    FontLoaderSub/ttf_parser.c
)

# --------------------------------------------------------------------------
# Platform-specific configuration
# --------------------------------------------------------------------------
if(APPLE)
    # Make wchar_t 2 bytes (UTF-16) to match the Windows behaviour assumed
    # throughout the code base.
    add_compile_options(-fshort-wchar)

    set(CLI_SOURCES
        FontLoaderSub/util_posix.c
        FontLoaderSub/path_posix.c
        FontLoaderSub/font_load_mac.c
        FontLoaderSub/main_mac.c
    )

    find_library(CORE_TEXT_LIB CoreText REQUIRED)
    find_library(CORE_FOUNDATION_LIB CoreFoundation REQUIRED)
    set(CLI_LIBS ${CORE_TEXT_LIB} ${CORE_FOUNDATION_LIB})

    option(MACOS_GUI "Build macOS menu-bar .app bundle" OFF)
    if(MACOS_GUI)
        find_library(APP_KIT_LIB AppKit REQUIRED)
        set(GUI_SOURCES
            FontLoaderSub/mac_gui/FLBridge.m
            FontLoaderSub/mac_gui/FLManager.m
            FontLoaderSub/mac_gui/AppDelegate.m
            FontLoaderSub/mac_gui/main_mac_gui.m
        )
    endif()

elseif(WIN32)
    set(PLATFORM_SOURCES
        FontLoaderSub/util.c
        FontLoaderSub/path.c
        FontLoaderSub/exporter.c
        FontLoaderSub/shortcut.c
        FontLoaderSub/main.c
    )
    set(PLATFORM_LIBS bcrypt shlwapi)

    # Resource file (dialogs, icons, strings)
    set(PLATFORM_SOURCES ${PLATFORM_SOURCES} FontLoaderSub/res/res.rc)

else()
    message(FATAL_ERROR "Unsupported platform. Only macOS and Windows are supported.")
endif()

# --------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------
if(APPLE)
    add_executable(fontloadersub
        ${COMMON_SOURCES}
        ${CLI_SOURCES}
    )

    target_include_directories(fontloadersub PRIVATE FontLoaderSub)
    target_link_libraries(fontloadersub PRIVATE ${CLI_LIBS})

    if(MACOS_GUI)
        add_executable(FontLoaderSubGUI MACOSX_BUNDLE
            ${COMMON_SOURCES}
            FontLoaderSub/util_posix.c
            FontLoaderSub/path_posix.c
            FontLoaderSub/font_load_mac.c
            ${GUI_SOURCES}
        )

        set_target_properties(FontLoaderSubGUI PROPERTIES
            MACOSX_BUNDLE_INFO_PLIST
                "${CMAKE_CURRENT_SOURCE_DIR}/FontLoaderSub/mac_gui/Info.plist"
        )

        target_include_directories(FontLoaderSubGUI PRIVATE
            FontLoaderSub
            FontLoaderSub/mac_gui
        )
        target_link_libraries(FontLoaderSubGUI PRIVATE
            ${CORE_TEXT_LIB}
            ${CORE_FOUNDATION_LIB}
            ${APP_KIT_LIB}
        )
        target_compile_options(FontLoaderSubGUI PRIVATE
            -Wall
            -Wextra
            -Wno-unused-parameter
            -Wno-incompatible-pointer-types
        )
    endif()
else()
    add_executable(fontloadersub
        ${COMMON_SOURCES}
        ${PLATFORM_SOURCES}
    )

    target_include_directories(fontloadersub PRIVATE FontLoaderSub)
    target_link_libraries(fontloadersub PRIVATE ${PLATFORM_LIBS})
endif()

# --------------------------------------------------------------------------
# Compiler warnings
# --------------------------------------------------------------------------
if(APPLE)
    target_compile_options(fontloadersub PRIVATE
        -Wall
        -Wextra
        -Wno-unused-parameter
        # -fshort-wchar triggers this on macOS SDK headers; suppress it.
        -Wno-incompatible-pointer-types
    )
endif()
