# Windows 开发环境

在 Windows 10/11 x64 的 PowerShell 中，从仓库根目录执行下列命令。仓库和构建路径需要不含空格、括号及 shell 特殊字符。工具、依赖、第三方源码和下载缓存全部放在 `toolchain/`，仿真和综合结果放在 `build/`。使用 Windows 原生 Verilator、MinGW GCC、Yosys/ABC、OpenSTA；MSYS2 提供 Make、Bash 等 Windows 构建辅助程序。无需 Docker、WSL 或 Linux 虚拟机。

## 安装与检查

首次安装需要网络，宿主机需要 Git、curl 和 tar（Windows 自带后两者）。当前工作区已安装工具，检查即可：

```powershell
.\toolchain\oss-cad-suite\lib\python3.exe toolchain/windows.py doctor
```

换一台机器或重新安装时：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File toolchain/setup.ps1 -Jobs 4
```

安装脚本下载并校验 `versions.json` 中固定版本的 OSS CAD Suite 和 MSYS2 基础包，在本目录安装 MinGW 编译依赖，并编译 OpenSTA/CUDD。OpenSTA、CUDD、ASAP7 的提交与项目 Dockerfile 相同；Verilator/Yosys 使用 Windows 套件版本，不能把两种环境的数值当成完全相同版本的测量。MSYS2 包使用安装时的仓库版本，实际包版本记入 `installed.json`。重复安装会复用已存在的基础环境、源码和下载缓存，并更新 MSYS2 包。

安装可能需要数 GB 磁盘和数分钟时间。基础包、ASAP7 压缩包使用 SHA-256 校验，第三方许可证保存在各工具目录中。`prepare-opensta.py` 只调整本目录第三方 OpenSTA 的 Tcl 构建命令。生成的二进制、源码和缓存已由 `toolchain/.gitignore` 排除。

## 日常使用

分别运行正确性、性能和综合的快捷脚本：

```powershell
.\toolchain\test.ps1 --jobs 4
.\toolchain\perf.ps1 --jobs 4
.\toolchain\synth.ps1 --out build/windows-synth --clock-period 5

# 复用已有仿真器；修改 RTL 后应先重新构建
.\toolchain\perf.ps1 --sim build/windows/sim.exe
.\toolchain\test.ps1 --sim build/windows/sim.exe --case correctness_add_to_100
```

三个脚本自动使用本目录自带的 Python 和工具链，无需激活环境。参数原样传给 `windows.py`，使用上例的双连字符形式。`test.ps1` 运行全部 correctness，`perf.ps1` 运行全部 perf；未指定 `--sim` 时自动构建或复用与当前输入一致的仿真器。默认输出 `build/windows`、构建并行数为逻辑 CPU 数与 8 的较小值、测试并行数 4、上限 100000000 cycles、访存延迟 10。可用 `--jobs`、`--test-jobs`、`--out`、`--filelist`、`--testcases`、`--case`、`--max-cycles`、`--latency` 调整。每个并行仿真进程使用官方 256 MiB RAM，内存较小时降低 `--test-jobs`。

`synth.ps1` 执行 Yosys/ABC 综合与 OpenSTA 时序分析，默认输出 `build/synth/opt`，目标周期 2 ns；可用 `--out`、`--mode`、`--filelist`、`--clock-period` 调整，上例显式使用 5 ns。ABC 默认使用 `--abc-driving-cell INVx1_ASAP7_75t_R --abc-load-ff 5.0`，与课程入口一致，启用缓冲与单元尺寸优化；OpenSTA 的接口负载仍由课程时序脚本规定。所有相对参数路径以仓库根目录为基准，脚本也可通过绝对路径从其他目录调用。成功返回 0，失败保留原流程的非零退出码；工具未安装时提示运行 `setup.ps1`。若 PowerShell 的执行策略阻止脚本，可用 `powershell -NoProfile -ExecutionPolicy Bypass -File toolchain/test.ps1 --jobs 4`，其他脚本同理。

以下命令均使用本目录自带的 Python，不需要修改系统 PATH。`windows.py` 为子进程设置本地工具路径。

```powershell
# 构建；显式要求 SystemVerilog 2005，得到 build/windows/sim.exe
.\toolchain\oss-cad-suite\lib\python3.exe toolchain/windows.py build --jobs 4

# 官方正确性与性能程序集（复用上一步的仿真器）
.\toolchain\oss-cad-suite\lib\python3.exe toolchain/windows.py test --sim build/windows/sim.exe
.\toolchain\oss-cad-suite\lib\python3.exe toolchain/windows.py perf --sim build/windows/sim.exe

# 只运行一个程序；未传 --sim 时自动构建
.\toolchain\oss-cad-suite\lib\python3.exe toolchain/windows.py test --case correctness_add_to_100 --jobs 4

# 带监视器的独立构建；结果在 profile.json、sim.json 和逐程序日志中
.\toolchain\oss-cad-suite\lib\python3.exe toolchain/windows.py ipc-profile --jobs 4 --out build/windows-ipc
.\toolchain\oss-cad-suite\lib\python3.exe toolchain/windows.py ipc-profile --case perf_qsort --parameter WB_WIDTH=1 --jobs 4 --out build/windows-wb1
.\toolchain\oss-cad-suite\lib\python3.exe toolchain/windows.py branch-accuracy --case perf_qsort --jobs 4 --out build/windows-branch

# ASAP7 面积映射与 OpenSTA 时序分析；目标周期单位为 ns
.\toolchain\oss-cad-suite\lib\python3.exe toolchain/windows.py synth --out build/windows-synth --clock-period 5

# 调整 ABC 映射约束；默认 RTL 为双分派、双发射
.\toolchain\synth.ps1 --clock-period 2 --abc-driving-cell INVx1_ASAP7_75t_R --abc-load-ff 5.0

# 单程序运行、波形输出（PROGRAM.bin 及期望值自行替换）
.\toolchain\oss-cad-suite\lib\python3.exe toolchain/windows.py run PROGRAM.bin --expected 186 --sim build/windows/sim.exe --wave build/windows/trace.vcd
```

`test` 默认允许 100000000 cycles。仿真器始终使用官方 `scripts/sim.cpp`、RAM 模型和测试输出协议。`run`、`synth`、监视器入口继续接受对应官方/开发脚本参数，使用 `--help` 查看；Windows 适配层提供 `sim.exe` 和正斜杠路径处理。

需要交互使用 Yosys、波形查看器等工具时，可以只对当前 PowerShell 激活。激活脚本提供 `yosys`、`verilator`、`gtkwave` 函数，为 OSS CAD 工具选择配套 DLL；编译器、仿真器和 OpenSTA 使用 MinGW 的 DLL：

```powershell
. .\toolchain\activate.ps1
yosys -V
gtkwave build/windows/trace.vcd
```

## 生成完整报告

```powershell
.\toolchain\oss-cad-suite\lib\python3.exe scripts/dev/report-windows.py --jobs 4
```

顺序执行 correctness → perf → IPC profiling → synth。报告写到 `build/reports/report-windows@时间-commit_提交标题.txt`，对应 `.build/` 保存仿真器、完整日志、监视器统计和综合/时序结果。共享构建缓存默认在 `build/windows-report-cache`，可用 `--cache-dir` 更改；每份报告保存本次产物快照。记录 Git 提交、工作区状态、源码/库 SHA-256、实际工具版本和各阶段耗时；单项失败仍执行后续项，最后以非零退出码返回。成功的正确性部分输出每个用例的 cycles，性能部分输出 IPC 表。默认 correctness/IPC 限制为 100000000 cycles，perf 限制为 10000000 cycles，综合目标频率 500 MHz（周期 2 ns）；可用 `--clock-period` 覆盖。

```powershell
.\toolchain\oss-cad-suite\lib\python3.exe scripts/dev/report-windows.py --jobs 4 --output-dir build/windows-reports --clock-period 5 --perf-max-cycles 100000000
```

Linux/Docker 原有 Makefile 和 `report.py` 继续按原方式工作。Windows 使用以上入口，课程 `scripts/` 直属文件、`scripts/ram`、项目 README 和 `docs/` 保持原样。

## 加速日常迭代

Windows 入口默认用 `-O3` 编译 C++ 热路径和仿真运行库，保留官方 `scripts/sim.cpp`、波形支持、断言和 SystemVerilog 2005。`--optimization size` 可切回原来的 `-Os`，首次 `-O3` 编译可能略慢。`--jobs` 只控制编译，`--test-jobs` 控制同时运行的用例数；用例结果按官方顺序输出，cycles 和 IPC 仍取自官方协议。

仿真缓存按源码、filelist、字面量 include、监视器、顶层参数、编译选项和工具内容校验；输入不变时跳过编译。兼容配置下的 RTL 修改重新生成模型，由 Make 复用未变化的 C++ 对象。普通与监视构建分别缓存，构建失败不留下可复用的旧二进制。不要手工移动对象目录；路径变化会使缓存失效。

综合复用成功的完整面积/时序结果，并缓存 Yosys elaborate 和映射阶段。源码、库、工具、综合模式、目标周期、时钟端口、课程综合脚本、ABC 驱动单元与负载参数均参与校验；映射阶段校验输出目录中生成的 `abc.constr`，完整缓存同时校验其内容。产物缺失或内容变化会重新运行对应阶段。更改目标周期或 ABC 参数复用 elaborate，重新执行映射和 OpenSTA。首次综合沿用官方算法和约束，耗时仍取决于设计规模。

默认每次重新运行全部选中的仿真用例。显式加 `--reuse-results` 时，可复用完全相同仿真器、程序、答案、性能指标、周期上限、延迟和超时参数下的成功结果；失败结果不缓存，控制台和 JSON 会标明复用数量。`--force` 要求重新编译/综合，并关闭本次测试结果复用。`--sim` 继续接受用户指定的已有二进制；需要自动检查当前 RTL 时省略该参数。

```powershell
# 两个命令自动共享同一普通仿真器；全部用例仍实际执行
.\toolchain\test.ps1 --jobs 8 --test-jobs 4
.\toolchain\perf.ps1 --jobs 8 --test-jobs 4

# 第一次执行建立成功结果缓存，之后相同输入可快速复查
.\toolchain\test.ps1 --reuse-results
.\toolchain\perf.ps1 --reuse-results

# 输入一致时复用综合；显式全量重跑
.\toolchain\synth.ps1 --out build/windows-synth --clock-period 2
.\toolchain\test.ps1 --force --jobs 8
.\toolchain\synth.ps1 --out build/windows-synth --force --clock-period 2

# 完整报告复用构建与综合；可选复用成功的测试结果
.\toolchain\oss-cad-suite\lib\python3.exe scripts/dev/report-windows.py --jobs 8 --test-jobs 4 --reuse-results
# 只生成性能和综合报告
.\toolchain\oss-cad-suite\lib\python3.exe scripts/dev/report-windows.py --targets perf synth
```

Docker/Linux 可以选用独立的开发入口，保留原有课程入口：

```sh
make fast-test APPIMAGE= JOBS=8 TEST_JOBS=4 MAX_CYCLES=100000000
make fast-perf APPIMAGE= JOBS=8 TEST_JOBS=4 MAX_CYCLES=100000000
make fast-test APPIMAGE= JOBS=8 MAX_CYCLES=100000000 REUSE_RESULTS=1
make fast-synth APPIMAGE= CLOCK_PERIOD_NS=2
make fast-synth APPIMAGE= CLOCK_PERIOD_NS=2 FORCE=1
make fast-synth APPIMAGE= CLOCK_PERIOD_NS=2 ABC_DRIVING_CELL=BUFx2_ASAP7_75t_R ABC_LOAD_FF=1.0
```

也可直接用 `python3 scripts/dev/fast.py test --appimage '' --jobs 8 --test-jobs 4`。开发流程实现放在 `scripts/dev`；`toolchain/windows.py` 和本文档纳入版本控制，下载的工具、源码和安装缓存仍被忽略。

`report-windows.py` 和 Docker 的 `report.py` 均接受 `--clock-period`、`--abc-driving-cell`、`--abc-load-ff`，并把参数传入综合阶段。`make report` 和 `make fast-synth` 同样传递对应的 Make 变量。
