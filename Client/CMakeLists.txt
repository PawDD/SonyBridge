cmake_minimum_required(VERSION 3.5)
project(SonyHeadphonesClient)

set(CMAKE_CXX_STANDARD 20)

find_package(Threads REQUIRED)

add_executable(SonyHeadphonesClient)

add_definitions(-D__HEADPHONES_APP_VERSION__="0.4.1")

target_sources(SonyHeadphonesClient
    PRIVATE BluetoothWrapper.cpp
    ByteMagic.cpp
    CommandSerializer.cpp
    TimedMessageQueue.cpp
    CrossPlatformGUI.cpp "Headphones.cpp")

target_include_directories (SonyHeadphonesClient
    PRIVATE ${CMAKE_SOURCE_DIR}
)

if(UNIX AND NOT APPLE)
    set(LINUX TRUE)
endif()

if (WIN32 OR LINUX)
    set (DEAR_IMGUI TRUE)
endif()

if (DEAR_IMGUI)
    target_sources(SonyHeadphonesClient
        PRIVATE CrossPlatformGUI.cpp
        imgui/imgui.cpp
        imgui/imgui_draw.cpp
        imgui/imgui_tables.cpp
        imgui/imgui_widgets.cpp
        CascadiaCodeFont.cpp
    )

    target_include_directories (SonyHeadphonesClient
        PRIVATE ${CMAKE_SOURCE_DIR}/imgui
    )
endif ()

if (LINUX)
	target_sources(SonyHeadphonesClient
		PRIVATE linux/DBusHelper.cpp
		linux/LinuxBluetoothConnector.cpp
		linux/LinuxGUI.cpp
        linux/main.cpp
        imgui/backends/imgui_impl_glfw.cpp
        imgui/backends/imgui_impl_opengl3.cpp
    )

    set (CMAKE_MODULE_PATH ${CMAKE_SOURCE_DIR}/linux)

    set (OpenGL_GL_PREFERENCE GLVND)
	
    find_package(DBus REQUIRED)

    find_package(glfw3 REQUIRED)

    find_package(OpenGL REQUIRED)

    if ((NOT DBUS_FOUND) OR (NOT glfw3_FOUND) OR (NOT OPENGL_FOUND))
        message ( FATAL_ERROR 
        "Didn't find one of the packages. For Debian based systems, use:"
        "sudo apt install libbluetooth-dev libglfw3-dev libdbus-1-dev" )
    endif ()

    target_include_directories(SonyHeadphonesClient
        PRIVATE ${DBUS_INCLUDE_DIRS}
        ${OPENGL_INCLUDE_DIRS}
    )

    target_link_libraries(SonyHeadphonesClient
        PRIVATE ${DBUS_LIBRARIES}
        glfw
        bluetooth
        OpenGL::GL
    )

endif ()

if (WIN32)
    target_compile_definitions(SonyHeadphonesClient PRIVATE
        UNICODE _UNICODE
        NOMINMAX
        WIN32_LEAN_AND_MEAN)

    target_sources(SonyHeadphonesClient
        PRIVATE windows/WindowsGUI.cpp
        windows/main.cpp
        windows/WindowsBluetoothConnector.cpp
        imgui/backends/imgui_impl_dx11.cpp
        imgui/backends/imgui_impl_win32.cpp
    )

    # Non-MSVC toolchains have no #pragma comment(lib, ...), so name every import library here.
    target_link_libraries(SonyHeadphonesClient
        PRIVATE d3d11 dxgi d3dcompiler
        ws2_32 rpcrt4 bthprops
        dwmapi          # imgui_impl_win32.cpp
    )
endif ()

target_link_libraries(SonyHeadphonesClient
    PRIVATE Threads::Threads
)

if (WIN32 OR LINUX)
    add_custom_command(TARGET SonyHeadphonesClient POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CMAKE_CURRENT_SOURCE_DIR}/resources/devices"
            "$<TARGET_FILE_DIR:SonyHeadphonesClient>/resources/devices"
        COMMENT "Copying device hero images next to the binary")
endif()

# Offline protocol tests use the platform's configured C++ compiler (including
# native MSVC), rather than mixing an unrelated clang with Visual Studio's STL.
option(SONYBRIDGE_BUILD_PROTOCOL_TESTS "Build offline protocol regression tests" OFF)
if (SONYBRIDGE_BUILD_PROTOCOL_TESTS)
    enable_testing()
    add_executable(sonybridge-protocol-tests
        tests/HeadphonesProtocolTests.cpp BluetoothWrapper.cpp ByteMagic.cpp
        CommandSerializer.cpp Headphones.cpp)
    target_include_directories(sonybridge-protocol-tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    target_link_libraries(sonybridge-protocol-tests PRIVATE Threads::Threads)
    add_test(NAME protocol COMMAND sonybridge-protocol-tests)

    add_executable(sonybridge-conformance-tests
        tests/ProtocolConformanceTests.cpp ByteMagic.cpp CommandSerializer.cpp)
    target_include_directories(sonybridge-conformance-tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    add_test(NAME conformance-xm4 COMMAND sonybridge-conformance-tests
        "${CMAKE_CURRENT_SOURCE_DIR}/tests/conformance/fixtures/xm4_v1_frames.golden")
    add_test(NAME conformance-multipoint COMMAND sonybridge-conformance-tests
        "${CMAKE_CURRENT_SOURCE_DIR}/tests/conformance/fixtures/ult900n_v2_multipoint.golden")

    add_executable(sonybridge-metamorphic-tests
        tests/MetamorphicProtocolTests.cpp ByteMagic.cpp CommandSerializer.cpp)
    target_include_directories(sonybridge-metamorphic-tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    add_test(NAME metamorphic COMMAND sonybridge-metamorphic-tests)

    add_executable(sonybridge-readback-tests tests/WaitForDeviceStateTests.cpp)
    target_include_directories(sonybridge-readback-tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    target_link_libraries(sonybridge-readback-tests PRIVATE Threads::Threads)
    add_test(NAME write-readback COMMAND sonybridge-readback-tests)
endif()
