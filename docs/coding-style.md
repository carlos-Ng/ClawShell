# 编码风格（vncc / enclave 风格）

本文档描述项目采用的 C/C++ 编码风格，并给出与 **clang-format** 的对应关系，便于生成与维护 `.clang-format` 配置文件。

---

## 1. 基本原则

- **一致性优先**：与既定风格保持一致，便于未来代码合并/迁移。
- **Fail fast**：错误尽早返回，避免 silent wrong。
- **可读性**：宁可写清楚，也不要过度“聪明”的模板/宏技巧。
- **函数长度（强制）**：
  - 单个函数体建议控制在 **50–80 行**以内，且 **不得超过 100 行**。
  - 行数统计口径：**不包含注释与空行**。
  - 例外：包含大量 `switch...case` 的函数可适当放宽，但仍应优先通过拆分子函数/表驱动降低复杂度。

---

## 2. 缩进与制表符

| 规则 | 说明 |
|------|------|
| **缩进字符** | 使用 **Tab** 进行缩进（不使用空格缩进）。 |
| **Tab 宽度** | 显示宽度视为 **4 列**（与编辑器/IDE 设置一致）。 |
| **对齐** | 行内对齐（如多行参数对齐）使用 **空格**，不插入额外 Tab。 |
| **续行缩进** | 换行后的延续行在上一行基础上再缩进 **1 级**（即 1 个 Tab 或 4 列，与 Tab 宽度一致）。 |

示例（Tab 用 `→` 表示）：

```cpp
→void longFunction(SomeType a,
→                 OtherType b,
→                 int c)
→{
→→if (condition) {
→→→doSomething();
→→}
→}
```

---

## 3. 行宽

- **列限制**：每行不超过 **100 列**（含行尾注释；字符串字面量可适当放宽或拆行）。
- 超过行宽时优先在自然断点（逗号、运算符、括号后）换行，并遵循续行缩进与对齐规则。

---

## 4. 大括号与块

### 4.1 类、结构体、函数、枚举

- **左大括号 `{` 换行**（Allman 风格）：`{` 独占一行，与类/结构体/函数/枚举声明对齐。

示例：

```cpp
class Foo
{
public:
	void bar();
};

struct S
{
	int x;
};

void doSomething()
{
}

enum class E
{
	A,
	B,
};
```

### 4.2 控制语句（if / for / while / switch）

- **左大括号 `{` 与语句同一行**（Attach/K&R 风格）：`{` 紧跟 `)` 后，同一行。
- **if / else（强制）**：所有 `if`、`else` 分支无论后续语句是单行还是多行，**必须**换行并用 **`{ }`** 包裹；禁止省略大括号的单行写法（如 `if (x) foo();`）。

示例：

```cpp
if (cond) {
	foo();
} else {
	bar();
}

for (int i = 0; i < n; ++i) {
	process(i);
}

while (running) {
	poll();
}

switch (x) {
case 1:
	handleOne();
	break;
default:
	break;
}
```

禁止的写法（单行无大括号）：

```cpp
// 禁止
if (a > b) foo();
if (a > b) foo1(); else foo2();
```

### 4.3 命名空间

- **`namespace` 与 `{` 同一行**：每个 namespace 独占一行声明，左大括号不换行。

示例：

```cpp
namespace enclave {
namespace capability {
namespace ax {

void foo();

} // namespace ax
} // namespace capability
} // namespace enclave
```

- **禁止** `namespace A::B::C { ... }` 的紧凑写法（即不用 `CompactNamespaces`），每个 namespace 单独写以便与现有代码一致。

---

## 5. 类内布局与访问说明符

### 5.1 声明顺序

- 类内成员建议按以下顺序分组（每组内按需再排）：
  1. **public**
  2. **protected**
  3. **private**
- 同一访问段内常见顺序：类型/枚举 → 静态常量 → 构造/析构/赋值 → 接口方法 → 数据成员。

### 5.2 struct 与 class

- **struct**：仅用于“以数据为主、无或很少行为”的聚合；成员默认 public 可接受。
- **class**：有不变式、封装、多态时使用；默认 private。

---

## 6. 空格与标点

### 6.1 关键字与括号

- **控制语句**：`if` / `for` / `while` / `switch` 与 `(` 之间保留 **一个空格**。
- **函数调用/声明**：函数名与 `(` 之间 **不加空格**。

```cpp
if (x) { }
for (int i = 0; i < n; ++i) { }
foo(1, 2);
```

### 6.2 指针与引用

- **`*` 和 `&` 紧贴类型**（靠左），与变量名之间用空格分隔。

```cpp
int* p = nullptr;
const std::string& s = get();
void foo(const Foo* a, Bar& b);
```

### 6.3 逗号与分号

- 逗号后 **保留一个空格**；分号前不加空格（除非行尾注释）。
- `for` 循环中分号后保留一个空格：`for (int i = 0; i < n; ++i)`。

### 6.4 类型转换与模板

- C++ 风格转换：`static_cast<T>(x)`，尖括号内 **不加空格**（`template <typename T>` 的 `<` `>` 内保留空格）。
- 模板声明：`template <typename T>` 中关键字与 `<` 之间保留一个空格。

### 6.5 赋值与运算符

- 赋值号、二元运算符两侧各保留 **一个空格**（与可读性一致即可，不强制对齐到多列）。

---

## 7. 多行声明与调用

### 7.1 函数声明/定义

- 若参数列表过长需要换行，**每行一个参数**（不把多个参数挤在同一行）。
- 续行与首行参数 **对齐**（用空格对齐到首参列），或续行统一缩进一级。

示例（对齐风格，与当前代码一致）：

```cpp
static Result<nlohmann::json> handleGetUITree(IAXProvider&         provider,
                                               const nlohmann::json& params,
                                               int                   defaultDepth);
```

### 7.2 函数调用

- 长调用可换行，规则同声明：参数对齐或续行缩进，不在一行内堆积过多参数。

---

## 8. 头文件与预处理

### 8.1 文件扩展名与命名

| 类型 | 约定 | 示例 |
|------|------|------|
| C++ 源文件 | `.cc` | `ax_capability.cc` |
| C++ 头文件 | `.h` | `ax_capability.h` |
| Objective-C++（若存在） | `.mm` / `.h` | `ax_provider_macos.mm` |

- 文件名使用 **snake_case**；可与主类名或模块名对应（如 `AXCapability` → `ax_capability.cc`），不强求完全一致。

### 8.2 头文件自包含与前向声明

- **头文件应自包含**：`#include "foo.h"` 后，该头及其依赖应足以编译，不依赖包含顺序。
- **Include what you use**：源文件中只包含实际用到的头，避免传递依赖。
- 在能减少头依赖、缩短编译时间时，可优先使用**前向声明**（如仅用指针/引用时），再在 `.cc` 中包含完整定义。

### 8.3 行尾

- 统一使用 **LF**（Unix 风格）；若引入 `.editorconfig`，在其中指定，并与 CI/编辑器一致。

### 8.4 头文件保护

- 统一使用 **`#pragma once`**，不使用 `#ifndef` / `#define` / `#endif` 守卫。

### 8.5 include 顺序（建议）

1. 本文件对应的头文件（若有，如 `.cc` 对应 `.h`）。
2. 项目内头文件（`"..."`）。
3. **空一行**。
4. 标准库 / 系统 / 第三方头文件（`<...>`）。

**不强制**对 include 自动按字母排序（即不启用按字母排序的 include 整理）。

### 8.6 include/ 与模块目录

- **导出头文件**：放在 `include/` 下（对外 API 候选集合）。
- **内部头文件**：仅服务于某模块或实现细节、不对外共享的，放在对应 `<module>/` 下，与对应 `.cc` 同目录。

---

## 9. 命名规范

命名以本项目既有风格为主；未在文档中单独说明的部分（如局部变量、参数）按下表统一，以便与常见风格（如 Google C++ Style）在类型、变量等方面保持一致且易于阅读。

### 9.1 接口命名（强制）

- **接口类型**统一使用 **`XxxxxInterface`** 后缀命名（如 `ModuleInterface`、`CapabilityInterface`）。
- **禁止**使用 **`I` 前缀**的接口命名（如 `IAXProvider`）；该写法不符合本规范。
- 已有历史代码中的 `IXxx` 命名可暂时保留，**新代码及重构时**应改为 `XxxInterface` 形式（例如将 `IAXProvider` 改为 `AXProviderInterface`）。

### 9.2 类型、函数与变量

| 对象 | 风格 | 示例 |
|------|------|------|
| 类型 / 类 / 结构体 / 枚举 | `PascalCase` | `AXCapability`, `ModuleConfig` |
| 接口类型 | `XxxxxInterface` | `ModuleInterface`, `CapabilityInterface`, `AXProviderInterface` |
| 函数 / 方法 | `lowerCamelCase` | `buildCacheKey()`, `listWindows()` |
| 函数参数、局部变量 | `snake_case` | `window_id`, `max_depth`, `element_path` |
| 成员变量 | `trailing_underscore`（即 snake_case + 尾随 `_`） | `cache_key_`, `implement_` |
| 常量（含局部 const/constexpr） | `UPPER_SNAKE_CASE` | `TOKEN_BUFFER_RESERVE`, `MAX_DEPTH` |
| 命名空间 | 与类型一致，多级每级一行 | `namespace enclave {` |

- **常量**：禁止使用 `kXxxx` 前缀，统一 `UPPER_SNAKE_CASE`。

示例：

```cpp
constexpr u32 TOKEN_BUFFER_RESERVE = 256;
const int DEFAULT_MAX_DEPTH = 10;
```

### 9.3 枚举值

- **枚举值**命名与常量一致：**UPPER_SNAKE_CASE**（与项目常量风格统一）；禁止 `kXxx`。
- 优先使用 **`enum class`**（有作用域），避免裸 `enum` 污染外层命名空间。

示例：

```cpp
enum class AXElementCap {
	INVOCABLE,
	EDITABLE,
	SCROLLABLE,
	TOGGLEABLE,
};
```

### 9.4 宏

- 宏名称使用 **UPPER_SNAKE_CASE**。
- 若宏具有“跨文件/跨模块”作用域，建议加**项目或模块前缀**（如 `ENCLAVE_`、`AX_`），减少冲突。
- 能用 `constexpr` / 内联函数替代的，优先不用宏。

### 9.5 类型别名

- 类型别名与类型名一致：**PascalCase**。
- 优先使用 **`using`**，少用 `typedef`（如 `using ModuleFactory = ...`）。

### 9.6 模板参数

- 单字母可接受（如 `T`、`U`）；有语义时用 **PascalCase**（如 `typename Key`、`typename Value`）。

---

## 10. 注释

### 10.1 函数头注释（强制）

- **所有函数定义**（含成员函数、自由函数）必须在函数前添加函数头注释，至少包含：
  - **功能**：函数做什么（1–2 句）。
  - **入参**：每个参数的含义/单位/约束（如可为空、范围、是否所有权转移）。
  - **出参/返回值**：返回值含义；若返回 `Result<T>`，需说明成功/失败各代表什么。
- **注释语言**：统一使用 **中文**（含函数头注释与关键路径注释）。

推荐模板：

```cpp
// doThing 用于做 X，以实现 Y。
//
// 入参:
// - a: ...
// - b: ...
//
// 出参/返回:
// - Result<T>::Ok(...)：成功。
// - Result<T>::Err(...)：失败（说明失败原因）。
```

### 10.2 区块注释

- 可使用 `// ───...` 等分隔线划分文件内区块；格式由各文件保持一致即可。

### 10.3 文件头注释（可选）

- 若项目或法律要求，可在文件顶部增加**文件头注释**（版权、作者、简要说明）；格式与是否强制由项目统一决定，此处不强制。

### 10.4 类 / 结构体注释

- 对外暴露的**类、结构体、接口**建议在定义前有一两句**简要说明**（用途、职责）；与现有“函数头注释”风格一致，语言为中文。

### 10.5 TODO / FIXME

- 使用 **`// TODO: 说明`** 或 **`// FIXME: 说明`**；可选择性要求带简要说明，不强制要求作者/日期（除非项目 CI 有约定）。

---

## 11. C++ 语言与特性

### 11.1 C++ 标准

- 项目目标标准以 **CMake 配置为准**（当前 **C++20**）；新代码不依赖更高标准除非项目统一升级。

### 11.2 异常与 RTTI

- **异常**：与现有 **Result / Status** 错误模型一致；不在公共 API 中抛异常；若底层库抛异常，应在边界处捕获并转为 Result。
- **RTTI / dynamic_cast**：不鼓励；若确需多态类型判断，优先考虑虚函数或类型枚举等显式设计。

### 11.3 所有权与智能指针

- 所有权语义应明确：**优先 `std::unique_ptr`**；共享所有权时用 `std::shared_ptr`。
- 避免裸 `new`/`delete`；在已有 Result 与模块边界的代码中，与现有资源管理方式保持一致。

### 11.4 const 与 constexpr

- 不修改的引用/指针参数、成员 getter 等应标 **const**。
- 编译期常量使用 **constexpr**（或 `const`）；命名仍按常量规则（UPPER_SNAKE_CASE）。

### 11.5 继承与 override

- 重写虚函数必须写 **`override`**；不参与多态的不写 `virtual`。
- 单参构造函数若可能被隐式转换，应标 **`explicit`**（除非确有意图允许隐式转换）。

### 11.6 类型转换与 auto

- **禁止** C 风格转换 `(T)x`；使用 **static_cast / reinterpret_cast / const_cast** 等。
- **auto**：在类型明显、提高可读性时使用（如迭代器、lambda）；类型不明显或影响可读性时写显式类型。

---

## 12. 错误处理与返回值

- 沿用 enclave 风格：使用 **`Result<T>` / `Result<void>` + `Status`**（状态码）。
- 错误尽早返回；禁止 silent wrong；能力不满足时返回 `NOT_SUPPORTED`（或等价错误码）。

---

## 13. 日志与测试

- **日志**：建议统一宏 `LOG_DEBUG` / `LOG_INFO` / `LOG_WARN` / `LOG_ERROR`（fmt 风格格式串），在 `common/log.*` 中保持全项目一致。
- **测试**：后续引入单测时，建议使用 GTest，并遵循 Firecracker 风格。

---

## 14. 短语句与单行块

- **短函数**：不强制单行写完；允许 `const char* name() const { return "ax"; }` 形式，但不要求所有短函数都压成一行。
- **短 if/for/while**：若写在同一行可读性好可接受；否则换行加大括号，与 4.2（控制语句大括号）一致。
- **空块**：`{ }` 可接受；若需注释则换行书写。

（以上为风格倾向，具体可由 clang-format 的 AllowShort* 系列选项在生成 `.clang-format` 时统一。）

---

## 附录 A：与 clang-format 的对应关系

以下列出与本风格文档对应的 **clang-format 选项**，便于生成或校核 `.clang-format` 文件。选项以 clang-format 官方名称为准，取值与本文档一致。

### A.1 缩进与制表符

| 选项 | 推荐值 | 说明 |
|------|--------|------|
| `Language` | `Cpp` | C++ 为主。 |
| `UseTab` | `Always` | 缩进使用 Tab。 |
| `TabWidth` | `4` | Tab 显示宽度。 |
| `IndentWidth` | `4` | 续行等缩进宽度（与 Tab 一致）。 |
| `ContinuationIndentWidth` | `4` | 换行延续缩进。 |

### A.2 行宽

| 选项 | 推荐值 | 说明 |
|------|--------|------|
| `ColumnLimit` | `100` | 每行最大列数。 |

### A.3 大括号（BraceWrapping）

需使用 **Custom** 并配合 **BraceWrapping** 子项：

| 选项 | 推荐值 | 说明 |
|------|--------|------|
| `BreakBeforeBraces` | `Custom` | 大括号由 BraceWrapping 细控。 |
| `BraceWrapping.AfterClass` | `true` | 类：`{` 换行。 |
| `BraceWrapping.AfterStruct` | `true` | 结构体：`{` 换行。 |
| `BraceWrapping.AfterFunction` | `true` | 函数：`{` 换行。 |
| `BraceWrapping.AfterEnum` | `true` | 枚举：`{` 换行。 |
| `BraceWrapping.AfterNamespace` | `false` | 命名空间：`{` 不换行。 |
| `BraceWrapping.AfterControlStatement` | `Never` | if/for/while/switch：`{` 不换行。 |
| `BraceWrapping.AfterCaseLabel` | `false` | case 后大括号风格与现有代码一致即可（可按需设为 `true`）。 |

### A.4 指针与引用

| 选项 | 推荐值 | 说明 |
|------|--------|------|
| `DerivePointerAlignment` | `false` | 不随文件推导。 |
| `PointerAlignment` | `Left` | `*` / `&` 靠类型。 |

### A.5 空格

| 选项 | 推荐值 | 说明 |
|------|--------|------|
| `SpaceBeforeParens` | `ControlStatements` | 仅控制语句后 `(` 前有空格。 |
| `SpaceInEmptyParentheses` | `false` | `()` 内无空格。 |
| `SpacesInParentheses` | `false` | 括号内侧不加空格。 |
| `SpacesInAngles` | `false` | 模板尖括号内无空格（如 `vector<int>`）；`template <typename T>` 由 SpaceAfterTemplateKeyword 等控制。 |
| `SpaceAfterTemplateKeyword` | `true` | `template` 与 `<` 之间保留空格。 |
| `SpaceBeforeAssignmentOperators` | `true` | 赋值号前有空格。 |
| `SpaceBeforeCtorInitializerColon` | `true` | 构造函数初始化列表冒号前有空格。 |
| `SpaceBeforeInheritanceColon` | `true` | 继承列表冒号前有空格。 |
| `SpaceBeforeRangeBasedForLoopColon` | `true` | 范围 for 冒号前有空格。 |

### A.6 多行与对齐

| 选项 | 推荐值 | 说明 |
|------|--------|------|
| `AlignAfterOpenBracket` | `Align` | 多行时括号内参数/表达式对齐。 |
| `BinPackParameters` | `false` | 多行时参数不挤在一行，便于对齐。 |
| `BinPackArguments` | `false` | 多行调用时参数不挤在一行。 |
| `AllowAllParametersOfDeclarationOnNextLine` | `false` | 声明换行时不全放在下一行，保持每行一个参数或对齐。 |

### A.7 include

| 选项 | 推荐值 | 说明 |
|------|--------|------|
| `SortIncludes` | `false` | 不按字母排序 include。 |
| `IncludeBlocks` | `Preserve` 或按需 | 保持现有分块（本文件头 → 项目头 → 空行 → 系统/第三方）。 |

### A.8 行尾

| 选项 | 推荐值 | 说明 |
|------|--------|------|
| `LineEnding` | `LF` | 换行符统一为 Unix 风格（与 8.3 一致）。 |

### A.9 其它常用

| 选项 | 推荐值 | 说明 |
|------|--------|------|
| `AccessModifierOffset` | `-2` 或与现有代码一致 | 访问说明符（public/protected/private）缩进，可选。 |
| `AllowShortFunctionsOnASingleLine` | `Empty` 或 `Inline` | 允许空或单行内联函数单行。 |
| `AllowShortIfStatementsOnASingleLine` | `Never` 或 `WithoutElse` | 与 4.2 一致，避免短 if 与 brace 风格冲突。 |
| `AllowShortBlocksOnASingleLine` | `Never` | 块不压成单行。 |
| `AllowShortLoopsOnASingleLine` | `false` | 循环体不压成单行。 |
| `MaxEmptyLinesToKeep` | `1` | 连续空行保留 1 行。 |
| `ReflowComments` | `true` 或 `false` | 可按需决定是否重排注释。 |
| `AlignTrailingComments` | `true` | 行尾注释对齐。 |
| `FixNamespaceComments` | `true` | 命名空间结尾注释 `// namespace xxx` 自动修正。 |
| `Standard` | `c++20` 或 `Latest` | 与项目 CMake 一致。 |

---

## 附录 B：生成 .clang-format 的简要步骤

1. 使用 `clang-format -style=llvm -dump-config` 得到一份完整 YAML。
2. 在 YAML 中按 **附录 A** 修改上述选项（尤其是 `UseTab`、`BreakBeforeBraces` + `BraceWrapping`、`PointerAlignment`、`ColumnLimit`、`SortIncludes`、`BinPackParameters` / `AlignAfterOpenBracket`、`LineEnding`）。
3. 将配置文件保存为项目根目录下的 **`.clang-format`**。
4. 建议同时提供 **`.editorconfig`**（若引入），使 Tab 宽度、缩进、行尾（LF）等与本文档及 `.clang-format` 一致。

---

*文档版本：基于原 8.x 节整理并扩展，已纳入文件/类/命名/语言特性等补充，便于与 clang-format 对应。*
