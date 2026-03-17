# ─── clawshell_vmm 静态库 ─────────────────────────────────────────────────────
#
# WSL2 VM 生命周期管理 + Hyper-V vsock 通信层。
# 源文件：
#   vm/vm_manager.cc    — WslVMManager（COM / wslapi / wsl.exe 多路径 distro 管理）
#   ipc/vsock_server.cc — WindowsVsockServer（AF_HYPERV Channel 3 传输层）

add_library(clawshell_vmm STATIC
    vm/vm_manager.cc
    ipc/vsock_server.cc
)

# vmm/ 内部私有头文件（hvsocket_defs.h, wsl_com_interfaces.h）
target_include_directories(clawshell_vmm PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

# 公共头文件（include/vmm/*.h）+ third-party（spdlog 等）
target_link_libraries(clawshell_vmm PUBLIC clawshell_headers)

# Windows 系统库
if(WIN32)
    target_link_libraries(clawshell_vmm PRIVATE
        ole32       # CoInitializeEx, CoCreateInstance（COM）
        ws2_32      # Winsock2（AF_HYPERV vsock）
        shlwapi     # SHDeleteKeyW（注册表清理）
    )
endif()

# ─── vmm.exe ────────────────────────────────────────────────────────────────
#
# 每个 WSL2 distro 对应一个 vmm.exe 实例：
#   - Watchdog 循环：定期检查 distro 状态，意外停止时自动重启
#   - Channel 1 IPC Client：连接 daemon Named Pipe，上报心跳/事件
#   - 接收 daemon 管理命令（启动/停止/快照等）

add_executable(clawshell_vmm_exe
    main.cc
    vmm_app.cc
)
set_target_properties(clawshell_vmm_exe PROPERTIES
    OUTPUT_NAME "vmm"
)
target_include_directories(clawshell_vmm_exe PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_link_libraries(clawshell_vmm_exe PRIVATE
    clawshell_vmm
    clawshell_ipc
    clawshell_headers
)
target_compile_definitions(clawshell_vmm_exe PRIVATE
    CLAWSHELL_VERSION="${PROJECT_VERSION}"
)
