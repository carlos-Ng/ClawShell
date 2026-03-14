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

# ─── vmm.exe 占位 ────────────────────────────────────────────────────────────
#
# 未来每个 distro 对应一个 vmm.exe 实例（watchdog + Channel 1 管道服务端）。
# 当前仅占位，不参与 ALL_BUILD（EXCLUDE_FROM_ALL）。

add_executable(clawshell_vmm_exe EXCLUDE_FROM_ALL
    main.cc
)
set_target_properties(clawshell_vmm_exe PROPERTIES
    OUTPUT_NAME "vmm"
)
target_link_libraries(clawshell_vmm_exe PRIVATE
    clawshell_vmm
    clawshell_headers
)
