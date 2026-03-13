# ─── capability_ax: Windows UI Automation capability plugin ─────────────────
#
# Builds capability_ax.dll, the ax GUI capability module.
# Loaded by ModuleManager at runtime via GetModuleInstance().
#
# Build:  cmake --build <build_dir> --target ax
# Or:     make ax

add_library(capability_ax SHARED
    ax_element.cc
    ax_text_serializer.cc
    ax_capability.cc
)

target_include_directories(capability_ax
    PRIVATE
        ${CMAKE_SOURCE_DIR}/include
        ${CMAKE_SOURCE_DIR}/third_party
        ${CMAKE_CURRENT_SOURCE_DIR}
)

if(WIN32)
    target_sources(capability_ax PRIVATE ax_provider_windows.cc)
    target_compile_options(capability_ax PRIVATE /W4 /WX-)
    target_link_libraries(capability_ax PRIVATE
        clawshell_core
        uiautomationcore
        ole32
        oleaut32
    )
# if(APPLE) 分支：未来合并 macOS 代码时在此添加 ApplicationServices/AppKit/Carbon 链接
endif()

set_target_properties(capability_ax PROPERTIES
    OUTPUT_NAME  "capability_ax"
    # 输出到 build/daemon-service/，与 config 中 module_dir = "build/daemon-service" 一致
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/daemon-service"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/daemon-service"
)

# Convenience alias: `cmake --build . --target ax`
add_custom_target(ax
    DEPENDS capability_ax
    COMMENT "Building capability_ax.dll"
)
