# 顶层 Makefile（兼容 Windows nmake / GNU make）
# 委托给 CMake 构建系统（daemon + UI 统一构建）
#
# 初次配置：
#   cmake -S . -B build -G "Visual Studio 17 2022" -A x64
#
# 典型用法：
#   make          # 构建 daemon + UI（等价于 cmake --build build）
#   make dist     # 打包到 dist/：daemon exe、dll、UI exe、config
#   make ax       # 仅构建 capability_ax.dll
#   make clean    # 清理构建产物
#   make run-ui   # 在开发模式下直接运行 UI（无需先 dist）

BUILD_DIR := build

.PHONY: all dist clean ax run-ui

all:
	cmake --build $(BUILD_DIR)

dist:
	cmake --build $(BUILD_DIR) --target dist

ax:
	cmake --build $(BUILD_DIR) --target capability_ax

clean:
	cmake --build $(BUILD_DIR) --target clean

run-ui:
	cd ui && dotnet run
