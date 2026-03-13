cmake_minimum_required(VERSION 3.20)

# ─── 项目声明 ─────────────────────────────────────────────────────────────────
# Windows 平台无 ObjC++，只需 CXX。
# 未来合并 macOS 代码时，在此添加 if(APPLE) 分支并补充 OBJCXX 语言。
project(ClawShell VERSION 0.1.0 LANGUAGES CXX)

# ─── Global C++ standard ──────────────────────────────────────────────────────

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ─── Windows 特定全局设置 ─────────────────────────────────────────────────────

if(WIN32)
    # UNICODE/WIN32_LEAN_AND_MEAN 全局有效，避免各 target 重复定义
    add_compile_definitions(UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
    # Windows SDK 最低版本：Windows 10（Named Pipe + UIA 均需要）
    add_compile_definitions(_WIN32_WINNT=0x0A00)
    # 强制 MSVC 以 UTF-8 解析源文件（解决含中文注释的头文件在 GBK 代码页下的解析错误）
    add_compile_options(/utf-8)
endif()

# ─── Third-party: header-only interface targets ───────────────────────────────

add_library(tp_nlohmann INTERFACE)
target_include_directories(tp_nlohmann INTERFACE
    ${CMAKE_SOURCE_DIR}/third_party
)

add_library(tp_expected INTERFACE)
target_include_directories(tp_expected INTERFACE
    ${CMAKE_SOURCE_DIR}/third_party/expected/include
)

add_library(tp_spdlog INTERFACE)
target_include_directories(tp_spdlog INTERFACE
    ${CMAKE_SOURCE_DIR}/third_party/spdlog/include
)

add_library(tp_tomlplusplus INTERFACE)
target_include_directories(tp_tomlplusplus INTERFACE
    ${CMAKE_SOURCE_DIR}/third_party/tomlplusplus/include
)

add_library(tp_jsonrpccxx INTERFACE)
target_include_directories(tp_jsonrpccxx INTERFACE
    ${CMAKE_SOURCE_DIR}/third_party/json-rpc-cxx/include
)

add_library(tp_cxxopts INTERFACE)
target_include_directories(tp_cxxopts INTERFACE
    ${CMAKE_SOURCE_DIR}/third_party/cxxopts/include
)

# Convenience bundle: all third-party headers in one target
add_library(third_party INTERFACE)
target_link_libraries(third_party INTERFACE
    tp_nlohmann
    tp_expected
    tp_spdlog
    tp_tomlplusplus
    tp_jsonrpccxx
    tp_cxxopts
)

# ─── Project public headers ───────────────────────────────────────────────────

# clawshell_headers: project-wide include/ + all third-party headers.
# Link against this target to get everything needed by most modules.
add_library(clawshell_headers INTERFACE)
target_include_directories(clawshell_headers INTERFACE
    ${CMAKE_SOURCE_DIR}/include
)
target_link_libraries(clawshell_headers INTERFACE third_party)

# ─── Core library ────────────────────────────────────────────────────────────

add_library(clawshell_core STATIC
    daemon-service/core/module_config.cc
    daemon-service/core/security_chain.cc
    daemon-service/core/module_manager.cc
    daemon-service/core/capability_service.cc
    daemon-service/core/task_registry.cc
)
target_link_libraries(clawshell_core PUBLIC clawshell_headers)

# ─── IPC library ─────────────────────────────────────────────────────────────
# 平台无关部分（帧编解码）始终编译。
# 平台相关的 IPC 实现由 if(WIN32)/if(APPLE) 分支选择，对应同一套 IpcServerInterface 抽象。

add_library(clawshell_ipc STATIC
    daemon-service/ipc/frame.cc
    daemon-service/ipc/ui_service.cc
)

if(WIN32)
    target_sources(clawshell_ipc PRIVATE
        daemon-service/ipc/windows_ipc_server.cc
        daemon-service/ipc/windows_ipc_client.cc
    )
# if(APPLE) 分支：未来合并 macOS 代码时在此添加 unix_ipc_server.cc / unix_ipc_client.cc
endif()

target_include_directories(clawshell_ipc PRIVATE ${CMAKE_SOURCE_DIR}/daemon-service/ipc)
target_link_libraries(clawshell_ipc PUBLIC clawshell_headers)

# ─── Capability modules ───────────────────────────────────────────────────────

add_subdirectory(daemon-service/capability/ax)

# ─── Security modules ─────────────────────────────────────────────────────────

add_library(security_filter SHARED
    daemon-service/security/filter/security_filter.cc
)
target_include_directories(security_filter PRIVATE
    ${CMAKE_SOURCE_DIR}/daemon-service/security/filter
)
target_link_libraries(security_filter PRIVATE clawshell_core clawshell_headers)

# ─── Daemon executable ───────────────────────────────────────────────────────

add_executable(crew_shell_service
    daemon-service/daemon/main.cc
    daemon-service/daemon/daemon.cc
)
target_include_directories(crew_shell_service PRIVATE
    ${CMAKE_SOURCE_DIR}/daemon-service/daemon
    ${CMAKE_SOURCE_DIR}/daemon-service
)
target_link_libraries(crew_shell_service PRIVATE
    clawshell_core
    clawshell_ipc
    clawshell_headers
)
target_compile_definitions(crew_shell_service PRIVATE
    CLAWSHELL_VERSION="${PROJECT_VERSION}"
)

# ─── UI (C# WinForms) ────────────────────────────────────────────────────────
# clawshell_ui 随 ALL_BUILD 一并构建，与 daemon 平行执行。
# dist target 会进一步 publish 为自包含单文件 exe，输出到 dist/bin/。

find_program(DOTNET_EXECUTABLE dotnet)
if(NOT DOTNET_EXECUTABLE)
    message(WARNING "dotnet not found — clawshell_ui target and UI packaging skipped")
else()
    # .NET 只接受 Debug / Release 两种配置名。
    # CMake 的 MinSizeRel / RelWithDebInfo 均映射到 Release。
    # DOTNET_CLI_UI_LANGUAGE=en-US：强制 dotnet CLI 输出英文，
    # 避免 Windows GBK 控制台下中文 UTF-8 输出乱码。
    add_custom_target(clawshell_ui ALL
        COMMAND ${CMAKE_COMMAND} -E env DOTNET_CLI_UI_LANGUAGE=en-US
                ${DOTNET_EXECUTABLE} build "${CMAKE_SOURCE_DIR}/ui"
                -c $<IF:$<CONFIG:Debug>,Debug,Release> --nologo -v quiet
        COMMENT "Building ClawShellUI (.NET 8 WinForms)"
        VERBATIM
    )
endif()

# ─── 发布目录 dist ───────────────────────────────────────────────────────────
#
# 用于手工测试与打包：将 daemon、dll、UI、config 复制到 dist/。
# 结构：dist/bin/{crew_shell_service.exe, ClawShellUI.exe}, dist/lib/*.dll, dist/config/*.toml
#
# 构建：cmake --build <build_dir> --target dist
# 运行：cd dist && .\bin\crew_shell_service.exe -f -c clawshell.toml

set(CLAWSHELL_DIST_DIR "${CMAKE_SOURCE_DIR}/dist")

# 按平台设置库文件扩展名与前缀
if(WIN32)
    set(CLAWSHELL_LIB_EXT ".dll")
    set(CLAWSHELL_LIB_PREFIX "")
    set(CLAWSHELL_EXE_EXT ".exe")
# if(APPLE) 分支：未来合并 macOS 代码时在此补充 .dylib 配置
endif()

add_custom_target(dist
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CLAWSHELL_DIST_DIR}/bin"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CLAWSHELL_DIST_DIR}/lib"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CLAWSHELL_DIST_DIR}/config"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        $<TARGET_FILE:crew_shell_service>
        "${CLAWSHELL_DIST_DIR}/bin/crew_shell_service${CLAWSHELL_EXE_EXT}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        $<TARGET_FILE:capability_ax>
        "${CLAWSHELL_DIST_DIR}/lib/${CLAWSHELL_LIB_PREFIX}capability_ax${CLAWSHELL_LIB_EXT}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        $<TARGET_FILE:security_filter>
        "${CLAWSHELL_DIST_DIR}/lib/${CLAWSHELL_LIB_PREFIX}security_filter${CLAWSHELL_LIB_EXT}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_SOURCE_DIR}/config/clawshell_dist.toml"
        "${CLAWSHELL_DIST_DIR}/config/clawshell.toml"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_SOURCE_DIR}/config/security_filter_rules.toml"
        "${CLAWSHELL_DIST_DIR}/config/security_filter_rules.toml"
    COMMENT "Populating dist/ with daemon, dlls and config"
    DEPENDS crew_shell_service capability_ax security_filter
)

if(DOTNET_EXECUTABLE)
    add_custom_command(TARGET dist POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E env DOTNET_CLI_UI_LANGUAGE=en-US
                ${DOTNET_EXECUTABLE} publish "${CMAKE_SOURCE_DIR}/ui"
                -r win-x64 -c Release
                -p:PublishSingleFile=true -p:SelfContained=true
                --nologo -v quiet
                -o "${CLAWSHELL_DIST_DIR}/bin"
        COMMENT "Publishing ClawShellUI to dist/bin"
        VERBATIM
    )
    add_dependencies(dist clawshell_ui)
endif()

# ─── Tests ───────────────────────────────────────────────────────────────────

option(BUILD_TESTS "Build test programs" OFF)
if(BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests/capability/ax)
    add_subdirectory(tests/core)
    add_subdirectory(tests/daemon)
    add_subdirectory(tests/ipc)
    add_subdirectory(tests/security/filter)
endif()
