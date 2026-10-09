# RV32IM 指令缓存乱序核接口规范

版本：v1.12.0。当前单发射优化以 Tier 2 面积 ≤18,000 µm²、六项 IPC 几何平均 ≥0.8 为目标（本轮放宽的 IPC 门槛）；按本轮要求将频率目标设为 ≥200 MHz，`make synth` 默认周期为 5.0 ns。第 17–20 节保留历史测量与配置，当前实现差异以第 21 节为准。本文定义成员 A、B 的实现接口；与 `plan.md` 冲突时以本文为准。外部接口遵守 [README](README-ZH.md) 和 [AXI 规范](docs/axi4-lite.md)。

## 1. 架构与实现边界

- RV32IM、乱序发射、按序提交、物理寄存器重命名；带 Instruction/Data Cache；带 BTB + 2-bit BHT；支持保守 Store-to-Load 转发，不投机越过未知 Store 地址；使用分支 checkpoint 和 16-bit generation。
- 默认启用全控制流预测；BTB 未命中时预测 PC+4，命中后条件分支使用 BHT 方向，JAL/JALR 使用 BTB 目标。一个取指包内按 PC+4 连续递增，并在首个预测 taken 处截断。分支执行产生真实下一 PC 时纠正误预测，不等待退休或 WB 仲裁。
- 正确路径指令受支持且访问合法；所有路径地址按访问宽度自然对齐。正确路径取指、Load 访问 RAM，Store 访问 RAM 或执行合法退出写。运行期间指令内存保持不变，不支持自修改代码或 Store 引起的 ICache 失效。无 CSR、特权陷入或精确异常状态。
- Store 仅在 ROB 头部获得外部写授权。RAM Load 可越过地址已知且字节范围不重叠的旧 Store；非 RAM Load 在本地返回零。
- 分支误预测只 squash 更年轻状态，保留该分支及更老工作；Fetch 立即切换 PC，Rename 从分支 checkpoint 恢复。桥继续完成旧事务，并在剩余容量内接收新路径请求。
- 接口只携带接收方消费的字段，不提供调试、退休轨迹、断言、额外诊断性一致性检查、超时、重试或配置检查电路。验证基础设施位于 tb，不增加 RTL 验证端口。

ICache 命中时每拍最多取得 D 个 32 位指令字；每包不跨 Cache line。缺失采用单行填充，允许填充期间其他有效行命中；逐字填充与数据读取共享总线。错误路径可以占用内部资源和读取 RAM，但不能改变已提交寄存器、内存或外设状态，不能触发退出。队列满时背压；除第 12 节明确的 generation 不回绕假设外，正确性不依赖错误路径长度或误预测次数的上限。未知编码转 NOP、非 RAM 读门控、身份匹配、generation 匹配、Store 授权和 squash 是这一功能要求的一部分。

| 模块 | 主责 | 职责 |
|---|---|---|
| student_top / fetch / branch_predictor / icache / decode | A | 接线、多指令取指、分支预测、指令缓存、译码 |
| rename / prf / rob / branch_ctrl | A | 重命名、寄存器、顺序提交、checkpoint/generation 恢复 |
| iq_alu / iq_mem / issue_sched | B | 就绪跟踪、候选选择、操作数读取 |
| alu × I / mul_div / wb_arb | B | 执行、完成仲裁、定向写回 |
| lsu / axi_bridge | B | AGU、LQ/SQ、Store 授权执行、总线 |

A 维护公共参数与位布局；类型采用普通 packed 向量，不要求 package/import。

## 2. 参数与线网约定

| 参数 | 默认 | 取值 |
|---|---:|---|
| ISSUE_WIDTH（I） | 1 | 1/2/4，全核每拍发射上限 |
| DISPATCH_WIDTH（D） | 1 | 1/2/4 |
| WB_WIDTH（W） | 2 | 1/2/4，每拍接受完成数 |
| COMMIT_WIDTH（C） | 2 | 1/2/4 |
| ROB_DEPTH（R） | 32 | 2 的幂，至少 8，且不小于 I/D/W/C |
| PRF_SIZE（P） | 48 | 至少 32+D |
| IQ_ALU_DEPTH / IQ_MEM_DEPTH | 7 / 4 | 正整数，至少 D；选择树补齐到 2 的幂 |
| LQ_DEPTH / SQ_DEPTH | 4 / 8 | 2 的幂，至少 D |
| FETCH_QUEUE_DEPTH（F） | 16 | 2 的幂，至少 D |
| IFETCH_OUTSTANDING | 8 | 1–16，不大于 F；当前路径已被 ICache 接受且未返回的指令槽数 |
| ICACHE_SIZE_BYTES | 1024 | 2 的幂，至少 ICACHE_WAYS × ICACHE_LINE_BYTES |
| ICACHE_WAYS | 2 | 1/2/4 |
| ICACHE_LINE_BYTES | 32 | 16/32/64 字节 |
| DCACHE_SIZE_BYTES | 16384 | 全部路的数据总容量，2 的幂，至少 DCACHE_WAYS × DCACHE_LINE_BYTES |
| DCACHE_WAYS | 2 | 1/2/4；1 路为直接映射，2/4 路为组相联 |
| DCACHE_LINE_BYTES | 64 | 16/32/64/128 字节；write-back/write-allocate |
| DATA_PREFETCH | 1 | 0/1；三个下一行预取 SRAM 缓冲，读请求只使用空闲通道 |
| BP_ENABLE | 1 | 0/1；关闭时顺序预测且停止训练 |
| BTB_ENTRIES | 32 | 2 的幂，至少 2，字地址索引、完整 tag、直接映射 |
| BHT_ENTRIES | 256 | 2 的幂，至少 2，独立 PC 字地址索引 |
| LOAD_OUTSTANDING | 4 | 1–16，不大于 LQ_DEPTH |
| AXI_RD_OUTSTANDING | 16 | 1–16，IF/LD 共享 |
| CHECKPOINT_DEPTH（K） | 4 | 1..R，控制流派遣前分配 |
| GEN_WIDTH | 16 | generation 位宽；在任何旧读事务存活期间不回绕碰撞 |
| RESET_PC | 32'h00000000 | RAM 内，4 字节对齐 |

XLEN 固定 32，不作为参数。LSU 最多 SQ_DEPTH 个已授权 Store，按授权顺序排队、每次等待一笔 DCache 写完成；AXI 桥允许多笔按序写回在途。参数满足上表是集成前提，不增加参数合法性检查。

Cache 组数 `S=ICACHE_SIZE_BYTES/(ICACHE_WAYS*ICACHE_LINE_BYTES)` 为 2 的幂，允许 S=1；行字数 `L=ICACHE_LINE_BYTES/4`。`IF_ID_WIDTH=IDX(L)` 用于填充字编号，`DCW=CNT(D)` 用于包 count。

DCache 组数 `DS=DCACHE_SIZE_BYTES/(DCACHE_WAYS*DCACHE_LINE_BYTES)` 同样为 2 的幂，允许 DS=1；总行数为 DS×DCACHE_WAYS。顶层默认 16 KiB、2 路、64 B 行，对应每路 128 组。独立 dcache 模块的 LINE_BYTES 默认仍为 32，由顶层显式传参。改变路数时总数据容量保持 DCACHE_SIZE_BYTES。

定义 `IDX(N)=max(1,ceil(log2(N)))`、`CNT(N)=max(1,ceil(log2(N+1)))`。`RW=IDX(R)`、`PW=IDX(P)`、`LIDW=IDX(LQ_DEPTH)`、`SIDW=IDX(SQ_DEPTH)`、`FIDW=IDX(F)`、`MIDW=max(LIDW,SIDW)`、`CIDW=IDX(K)`、`TAG_BITS=RW`（ROB tag 仅含 rob_id/index，不再携带 generation）。

ROB 身份为 `rob_tag_t={index}`（仅 rob_id/index）。活跃项年龄为 `(index-head) mod R`。ROB 用占用计数区分满/空。generation 不进入 ROB 身份，也不用于判断后端指令失效。

正常退休后的 ROB 槽、完成后的 LQ 槽可在下一拍复用；squash 后的槽也可在下一拍复用。旧 Load 返回仍带原 generation，`{gen,id}` 不匹配的数据只归还事务额度、不写新槽。旧取指包在 redirect 时由 ICache 取消，物理填充继续完成。generation 按模 `2^GEN_WIDTH` 自增，不显式回收；约定从任一读请求被桥接收到其响应返回期间不会发生回绕碰撞（见第 12 节）。

CPU 内部在途请求、运算和结果的身份均由其活跃 ROB 项覆盖。被 squash 的内部工作在该边沿取消，不能在后续周期重新产生旧结果；已经有效的失效结果同拍取消或被 WB 接收丢弃。只有 ICache 物理填充及桥内已接受读可以在相关路径失效后继续存在，其身份由 ICache/桥独立保持，用于 `{gen,id}` 匹配。这样编号回收不遗漏执行缓冲中的引用。

时序模块使用 clock 上升沿及高电平同步 reset。复位只初始化有效位、指针、计数和必要架构状态，不清空无效载荷。

类型字段按表中顺序从高位到低位打包，无 padding；lane 0 在扁平总线最低位。有序包 lane 0 最老。无效 lane、不适用字段和空槽内容不要求清零；只更新有效位及必要控制状态。语义零值（p0、不写目的时的 pdst=0、非 RAM Load 的结果零）仍必须生成。

- **保持型通道**：valid/ready/payload，在上升沿 valid&&ready 时接收；阻塞期间有效载荷保持。valid 不组合依赖 ready。
- **事件**：valid/payload，无 ready；接收方已具备空间，当拍全部接收。派遣、完成、唤醒、退休更新、读响应、Store 授权和写完成使用事件。
- **预览**：容量、候选、分配槽号可以每拍变化，仅在选中或派遣时采样。

reset 优先于所有事件。恢复按周期开始时的 ROB head 比较年龄：squash 取消年轻状态及其同拍事件，更老指令和触发分支本身的执行、写回、退休仍按正常条件生效；新派遣在 squash 当拍禁止。不能用全局 kill 屏蔽全部正常事件。已被桥接受的请求以及外部 AXI VALID 不能取消；任何读响应均归还事务额度（按 `{gen,id}` 决定是否写槽），包括恢复当拍及 generation 不匹配的响应。

## 3. 操作编码与最小载荷

### 3.1 操作编码

`op` 为 6 位。编码 0 是内部 NOP，46–63 不由 Decode 产生。分类由 op 推导，不携带 fu、源选择或指令类别标志。

| 编码 | 指令 | 编码 | 指令 | 编码 | 指令 |
|---:|---|---:|---|---:|---|
| 0 | NOP | 16 | ANDI | 32 | LW |
| 1 | LUI | 17 | SLLI | 33 | LBU |
| 2 | AUIPC | 18 | SRLI | 34 | LHU |
| 3 | JAL | 19 | SRAI | 35 | SB |
| 4 | JALR | 20 | ADD | 36 | SH |
| 5 | BEQ | 21 | SUB | 37 | SW |
| 6 | BNE | 22 | SLL | 38 | MUL |
| 7 | BLT | 23 | SLT | 39 | MULH |
| 8 | BGE | 24 | SLTU | 40 | MULHSU |
| 9 | BLTU | 25 | XOR | 41 | MULHU |
| 10 | BGEU | 26 | SRL | 42 | DIV |
| 11 | ADDI | 27 | SRA | 43 | DIVU |
| 12 | SLTI | 28 | OR | 44 | REM |
| 13 | SLTIU | 29 | AND | 45 | REMU |
| 14 | XORI | 30 | LB | | |
| 15 | ORI | 31 | LH | | |

内存指令使用 `mem_op=op-30` 的 3 位编码：0=LB、1=LH、2=LW、3=LBU、4=LHU、5=SB、6=SH、7=SW。乘除入口使用 `mul_op=op-38`：0=MUL、1=MULH、2=MULHSU、3=MULHU、4=DIV、5=DIVU、6=REM、7=REMU。

ROB 单独保存 2 位 `kind`：0=普通，1=控制流，2=Load，3=Store。ROB 不保存 op，kind 用于派遣分类、提交和 Store 授权；LSU 分配载荷中的 is_store 仅用于选择 LQ/SQ。

### 3.2 定向载荷

不定义完整的 renamed_uop 透传包。Rename 将同一条指令投影为不同接收方的载荷；公共字段共享产生逻辑，不为每份投影重复设置存储。

| 类型 | 字段（高位到低位） |
|---|---|
| `rob_tag_t` | `index:RW` |
| `fetch_packet_t` | `pc:32, inst:32, pred_npc:32` |
| `decoded_uop_t` | `pc:32, pred_npc:32, op:6, rs1:5, rs2:5, rd:5, imm:32` |
| `rob_alloc_t` | `old_pdst:PW, kind:2, sq_id:SIDW` |
| `alu_iq_t` | `rob:rob_tag_t, cp_id:CIDW, op:6, pdst:PW, ps1:PW, ps2:PW, pc:32, imm:32` |
| `mem_iq_t` | `rob:rob_tag_t, mem_op:3, mem_id:MIDW, ps1:PW, ps2:PW, imm:32` |
| `mem_alloc_t` | `is_store:1, mem_id:MIDW, rob:rob_tag_t, pdst:PW` |
| `alu_exec_t` | `rob:rob_tag_t, cp_id:CIDW, op:6, pdst:PW, pc:32, imm:32, rs1_value:32, rs2_value:32` |
| `mul_exec_t` | `rob:rob_tag_t, mul_op:3, pdst:PW, rs1_value:32, rs2_value:32` |
| `mem_exec_t` | `rob:rob_tag_t, mem_op:3, mem_id:MIDW, base:32, imm:32, data:32` |
| `result_t` | `rob:rob_tag_t, pdst:PW, value:32` |
| `branch_resolve_t` | `rob:rob_tag_t, cp_id:CIDW, pc:32, is_conditional:1, taken:1, target:32, npc:32` |
| `bp_train_t` | `pc:32, is_conditional:1, taken:1, target:32` |
| `cp_alloc_t` | `cp_id:CIDW, rob:rob_tag_t, pred_npc:32` |
| `fetch_redirect_t` | `target_pc:32, new_gen:GEN_WIDTH` |
| `reg_commit_t` | `old_pdst:PW` |
| `ic_req_t` | `gen:GEN_WIDTH, id:FIDW, count:DCW, addr:32` |
| `ic_rsp_t` | `gen:GEN_WIDTH, id:FIDW, count:DCW, inst:32×D` |
| `if_req_t` | `gen:GEN_WIDTH, id:IF_ID_WIDTH, addr:32` |
| `if_rsp_t` | `gen:GEN_WIDTH, id:IF_ID_WIDTH, data:32` |
| `ld_req_t` | `gen:GEN_WIDTH, id:LIDW, addr:32` |
| `ld_rsp_t` | `gen:GEN_WIDTH, id:LIDW, data:32` |
| `write_req_t` | `addr:32, data:32, strb:4` |

`inst` 到 Decode 为止。Decode 输出的 rs1/rs2 对不使用的源置 0，rd 对无目的寄存器的指令置 0；不携带 uses_rs、writes_rd。Rename 将无目的写编码为 pdst=0，后续以 pdst!=0 产生 PRF 写和唤醒，不携带 rd_we。

ROB 不保存 npc/mispred 或 checkpoint 副本。预测值保存在 branch_ctrl 的 checkpoint 元数据中，实际目标由 ALU 的一次性 branch_resolve 事件给出；普通完成只携带身份与寄存器结果，退休不再重定向。

ALU IQ/执行请求携带 cp_id，只有控制流操作消费；乘除入口不携带 cp_id/pc/imm。AGU 请求补入完整 ROB 身份，使发射缓冲和 AGU 可独立按年龄取消请求；LSU 队列仍保存该身份和 Load 的 pdst。pc/imm 只在对应执行路径消费，源物理编号在读出操作数后不继续传递。

`mem_id` 是 LQ/SQ 槽号的联合字段，由 is_store 或 mem_op 限定，不足位补零；槽号 0 合法。ROB 只保存 Store 的 sq_id。Load 结果被接收后释放 LQ，不向 ROB 传递 LQ 槽号。

派遣包内不携带 generation；后端投影直接包含完整 rob_tag_t。前端数据包不重复携带 generation：ICache 在 redirect 时取消旧包，Fetch 自己按 `{gen,id}` 筛选包响应，任何重定向都清空未派遣的旧前端状态。

### 3.3 位宽

下表位数对应第 2 节的顶层默认参数（D=I=1、W=C=2、R=32、P=48、LQ=4、SQ=8、F=16、K=4）。各模块独立例化时按其实际参数重算。

| 常量 | 公式 | 默认位数 |
|---|---|---:|
| `TAG_BITS` | RW | 5 |
| `FETCH_BITS` | 32 + 32 + 32 | 96 |
| `DECODE_BITS` | 32 + 32 + 6 + 5 + 5 + 5 + 32 | 117 |
| `ROB_ALLOC_BITS` | PW + 2 + SIDW | 11 |
| `ALU_IQ_BITS` | TAG_BITS + CIDW + 6 + PW + PW + PW + 32 + 32 | 95 |
| `MEM_IQ_BITS` | TAG_BITS + 3 + MIDW + PW + PW + 32 | 55 |
| `MEM_ALLOC_BITS` | 1 + MIDW + TAG_BITS + PW | 15 |
| `ALU_EXEC_BITS` | TAG_BITS + CIDW + 6 + PW + 32 + 32 + 32 + 32 | 147 |
| `MUL_EXEC_BITS` | TAG_BITS + 3 + PW + 32 + 32 | 78 |
| `MEM_EXEC_BITS` | TAG_BITS + 3 + MIDW + 32 + 32 + 32 | 107 |
| `RESULT_BITS` | TAG_BITS + PW + 32 | 43 |
| `RESOLVE_BITS` | TAG_BITS + CIDW + 98 | 105 |
| `BP_TRAIN_BITS` | 32 + 1 + 1 + 32 | 66 |
| `CP_ALLOC_BITS` | CIDW + TAG_BITS + 32 | 39 |
| `FETCH_REDIRECT_BITS` | 32 + GEN_WIDTH | 48 |
| `REG_COMMIT_BITS` | PW | 6 |
| `IC_REQ_BITS` | GEN_WIDTH + FIDW + DCW + 32 | 53 |
| `IC_RSP_BITS` | GEN_WIDTH + FIDW + DCW + 32×D | 53 |
| `IF_REQ_BITS` | GEN_WIDTH + IF_ID_WIDTH + 32 | 51 |
| `IF_RSP_BITS` | GEN_WIDTH + IF_ID_WIDTH + 32 | 51 |
| `LD_REQ_BITS` | GEN_WIDTH + LIDW + 32 | 50 |
| `LD_RSP_BITS` | GEN_WIDTH + LIDW + 32 | 50 |
| `MEM_LD_BITS` | GEN_WIDTH + DC_WORD_W + 32 | 52 |
| `AXI_LD_BITS` | MEM_LD_BITS + 2（预取槽编号） | 54 |
| `WRITE_REQ_BITS` | 32 + 32 + 4 | 68 |

## 4. 外部接口

student_top 保留课程规定的 AXI4-Lite 端口，不增加预测、调试或验证端口。

| 端口 | 方向 | 位宽 |
|---|---|---:|
| `clock` / `reset` | 输入 | 各 1 |
| `araddr` | 输出 | 32 |
| `arvalid` | 输出 | 1 |
| `arready` | 输入 | 1 |
| `rdata` | 输入 | 32 |
| `rresp` | 输入 | 2 |
| `rvalid` | 输入 | 1 |
| `rready` | 输出 | 1 |
| `awaddr` | 输出 | 32 |
| `awvalid` | 输出 | 1 |
| `awready` | 输入 | 1 |
| `wdata` | 输出 | 32 |
| `wstrb` | 输出 | 4 |
| `wvalid` | 输出 | 1 |
| `wready` | 输入 | 1 |
| `bresp` | 输入 | 2 |
| `bvalid` | 输入 | 1 |
| `bready` | 输出 | 1 |

RAM 小端，地址范围为 `0x00000000..0x0fffffff`。退出操作是向 `0x80000000` 的 SW，WSTRB=1111；从机在 B 握手时可终止仿真。外部 rresp/bresp 保留但不存储、不传播、不影响控制；合法访问正常完成为环境前提。请求完成由握手决定，不依赖固定内存延迟。

## 5. Fetch 与 Decode

### 5.1 多指令 Fetch

Fetch 每拍预留至多 D 个槽，每槽保存 pc/pred_npc/pred_taken/generation；预测器从 next_pc 并行查询 D 个连续 PC，返回 pred_taken[D] 和 pred_npc[32×D]。先应用容量、行尾及额度限制，再截到首个预测 taken 的 lane（包含该指令）；next_pc 设为其目标，否则按 count×4 前进。预留槽时锁存预测，不受后续训练影响。非 RAM 槽强制顺序预测。包内 PC 按模 2^32 连续递增，每包不跨 Cache line；队列空闲空间、行尾剩余字数或取指额度不足时取更短前缀。已有 offer 被背压时不再创建新 offer 或重复推进 PC。可在旧 offer 接受同拍建立下一包。就绪指令复制进输出缓冲时即释放源槽并推进队首，释放槽在下一拍参与分配；F 统计队列槽容量，输出缓冲另容纳一个至多 D 条的包。

RAM 内槽形成 ic_req 保持型请求，id 为首槽编号，count 为 1..D；lane k 的槽号为 (id+k) mod F。接受请求后按 count 增加 outstanding；ICache 为每个已接受包产生一次 ic_rsp 事件，含相同 gen/id/count 和按 lane 排列的指令字。Fetch 只消费当前 fetch_gen 的响应，每槽还必须处于 waiting 且 slot_gen 匹配，才写入 inst 并置 ready。当前路径响应按 count 归还额度；旧 generation 的包不写槽也不改变当前路径额度。RAM 外 PC 本地填 inst=0 并就绪，不占取指额度、不进入 ICache。

fetch_redirect 当拍取消未接受 offer 和旧输出，边沿清旧槽及当前路径 outstanding，设置目标 PC，并将 fetch_gen 更新为 payload.new_gen。generation 只由 branch_ctrl 产生。ICache 同拍取消旧等待包与旧命中响应，不再为取消的包返回事件；物理填充读数由 ICache/桥独立维护，不受 Fetch 清零影响。下一拍可创建新路径槽。复位 PC=RESET_PC、fetch_gen=0。

最老连续就绪的至多 D 个槽形成 fetch_packet；在锁存的首个 pred_taken 槽处截断输出，避免合并跳转前后两个路径，即使预测目标恰好等于 PC+4 也截断。预测跳转仅推进 next_pc，不清前端状态、不增加 generation。剩余槽在下一输出包消费。valid 时 count 为 1..D，整包接受。当拍 ic_rsp 的 gen/id/count 匹配队头 waiting 槽及 slot_gen 时，直接将响应指令字参与就绪前缀并装入输出缓冲，省去等待 state=ready 的一拍；输出背压时响应仍写入队列，旧 generation 不参与旁路。输出缓冲可在旧包接受的边沿装入后续就绪包，无输出空拍；复制后不再引用源槽，背压期间 count 和载荷保持。Decode 纯组合转换，count 原样传递；Rename 缓冲已接收的包。

### 5.2 Instruction Cache

ICache 当前顶层默认 1 KiB、2 路、32 B 行、16 组。完整 32 位地址拆成 tag、组号、行内字号。每路一个同步 1RW sram_fakeram，DEPTH=S、WIDTH=ICACHE_LINE_BYTES×8，整行写入；tag、valid 与每组替换指针用寄存器。复位只清 valid、替换指针及控制状态，不清 tag、SRAM 或无效载荷。

命中请求在接受边沿启动 SRAM 读，下一周期产生包响应；无写入冲突时可每拍接收一个包。替换先选最低编号无效路，否则选轮转指针；分配填充时立即使目标路无效，安装成功后将指针推进到该路的下一路。

唯一 MSHR 保存行地址、目标组/路、填充 generation、发送/返回计数、整行缓冲和一个可取消等待包。行按字号 0..L-1 逐字发 if_req，id 为行内字号，addr=line_base+4×id，每拍最多一笔，可多笔在途。桥响应按原 gen/id 写整行缓冲；填充读不占 IFETCH_OUTSTANDING。收齐后一个周期写整行 SRAM 并发布 tag/valid，等待包随后从填充缓冲返回；不做关键字优先或提前返回。

填充期间其他有效行可以命中。填充写入周期背压全部新包；第二个不同行 miss 等待 MSHR 释放。同一填充行在没有有效等待包时，可接收一个新等待包。每拍最多一个 ic_rsp，命中读取优先，填充完成包缓存在 MSHR 中直到能发送；安装且等待包已发送或取消后释放 MSHR。

fetch_redirect 当拍禁止取指包接收与响应，清命中响应状态及等待包，但保留有效缓存和物理填充，并继续发送、接收整行读事务。新路径命中可继续；同一填充行可重新建立等待包，不同行 miss 须等待。等待包 generation 与填充 generation 分别锁存，旧填充可向新 generation 的有效等待包供数。

Decode 生成已扩展的 imm：I/S/B/J 符号扩展，U 为 inst[31:12]<<12。LUI、AUIPC、JAL 不使用寄存器源；JALR、立即数运算和 Load 使用 rs1；条件分支、寄存器运算、Store、M 扩展使用 rs1/rs2。只有具有架构目的的操作保留 rd。op 决定 ALU 输入选择、访存大小和符号扩展，不重复传递这些控制位。

不支持或未知的指令编码（包括零填充、CSR、FENCE、FENCE.I、ECALL、EBREAK）输出 op=NOP、rs1=rs2=rd=0，不申请目的物理寄存器或访存槽。正确路径不会出现这些编码；此处理使错误预测进入任意 RAM 内容后仍能继续执行和 squash。

### 5.3 BTB + 2-bit BHT

预测器为独立 branch_predictor；BTB/BHT 用寄存器实现组合查询，每拍支持 D 路查询和 I 路训练，不使用 SRAM、不增加查询流水级。BTB 以 PC[2 +: $clog2(BTB_ENTRIES)] 为索引，其余高位为完整 tag，保存 valid/tag/target/is_conditional；BHT 以 PC[2 +: $clog2(BHT_ENTRIES)] 为独立索引，无 tag、无全局历史。表容量不得超过 32 位 PC 字地址索引空间，BTB 需保留至少一位 tag。复位只清 BTB valid，将 BHT 置 01（弱不跳转），不清无效 BTB 载荷。

BTB 未命中时 pred_taken=0、pred_npc=PC+4；命中条件分支时用 BHT 最高位判断 taken；命中 JAL/JALR 时无条件 taken。taken 时 pred_npc=BTB.target，即使 target=PC+4 也保持 pred_taken=1。非 RAM PC 或 BP_ENABLE=0 强制顺序预测；BP_ENABLE=0 不训练。无 RAS，不预译码冷启动 JAL，JALR 使用最近训练目标。

ALU 条件分支显式输出比较结果 taken，target 始终为 PC+imm（包括不跳转），npc=taken?target:PC+4；JAL/JALR 的 is_conditional=0、taken=1，target/npc 为实际目标。不能从 npc!=PC+4 推导 taken。branch_ctrl 仅接受有效 checkpoint 的 cp_id/tag 匹配事件，以恢复前 rob_head 的 RW 位模差计算年龄；最老误预测边界及更老解析可训练，其余解析丢弃。训练事件是无 ready 事件，与 WB 无关，每次解析只产生一次。

branch_ctrl 将存活事件压紧到 train lane 0..N-1，按 ROB 年龄从老到新输出。所有事件更新或直接替换对应 BTB 项；只有条件分支更新 BHT（taken 饱和加一、不跳转饱和减一）。同拍 BTB 索引冲突保留较年轻事件，同拍 BHT 索引冲突按事件顺序逐次饱和，不能仅取最后一次或合并成净增量。查询读取边沿前状态，无训练旁路；下一拍才能观察更新。执行后发生更老分支 squash 时，不回滚此前已写入的预测表；同拍被 squash 的年轻解析不写表。预测表不带 generation、不在 redirect 时清空。

## 6. Rename 与原子派遣

### 6.1 分配预览

| 来源 → Rename | 信号 | 含义 |
|---|---|---|
| ROB | rob_free、rob_tail | 可分配项数、单个尾索引；lane k 的 ROB 索引为 (rob_tail+k) mod R |
| 两个 IQ | alu_iq_free、mem_iq_free | 周期开始时空闲项数 |
| LSU | lq_free、sq_free | 周期开始时空闲项数 |
| LSU | lq_alloc_id[D]、sq_alloc_id[D] | 从空闲位图按编号递增给出候选槽 |
| branch_ctrl | cp_free、cp_alloc_id[D] | checkpoint 空闲数及最低编号候选 |

ROB 不输出可由尾索引推导的 D 份标签。LQ/SQ 完成顺序可以不同于分配顺序，保留空闲位图和候选槽列表。

### 6.2 派遣投影

Rename 保留一个译码包缓冲和一个派遣 offer。根据全部容量选取最大可容纳前缀，准备 count、ROB 索引、物理目的、访存槽及 checkpoint 候选；未选后缀留在译码缓冲。D=2/4 锁存准备结果，D=1 仅在背压时锁存已发布 offer。每个控制流指令消耗一个 checkpoint。offer 只在 disp_valid&&disp_ready 时原子生效，背压期间内容不变。

完整缓冲包派遣的同一边沿可以接收下一个译码包。D=1 时，缓冲指令根据当前 RAT、空闲表和资源预览组合形成 offer；消费当前指令与接收下一条在同一边沿发生，下一拍看到更新后的 RAT，持续输入且资源充足时每拍派遣一条。首次背压时将 offer 的全部投影及分支/前端纠正信息锁存，之后保持到消费或 squash；背压期间资源预览变化不会改写已发布载荷。D=2/4 保留 offer 准备寄存器，持续输入时每两拍派遣一个包。派遣背压、仅派遣前缀、前端纠正或 squash 当拍不进行缓冲替换。

| 投影 | 接收方 | 数据 |
|---|---|---|
| disp_rob[D] | ROB | rob_alloc_t |
| disp_alu[D] | ALU IQ | alu_iq_t，仅非访存 lane 有意义 |
| disp_mem[D] | MEM IQ | mem_iq_t，仅访存 lane 有意义 |
| disp_lsq[D] | LSU | mem_alloc_t，仅访存 lane 有意义 |
| disp_src1_ready/disp_src2_ready[D] | 两个 IQ | 源就绪侧带，在对应派遣事件采样 |
| cp_alloc_valid[D]、cp_alloc_payload[D] | branch_ctrl | 控制流 lane 的 cp_alloc_t 分配事件；Rename 同拍保存快照 |
| front_redirect_valid/front_redirect_pc | branch_ctrl | 非控制流错误预测的前端纠正事件，仅给出真实下一 PC |

顶层根据 disp_rob.kind 统计 need_alu/need_mem/need_lq/need_sq；统一 fire 为 `disp_valid && disp_ready`，disp_ready 由 !squash_valid 及四类队列和 ROB 的容量满足条件产生。Checkpoint 候选已在形成 offer 时锁定；除了这个 offer 没有其他新资源申请者，分支恢复只消费既有预留编号并取消旧 offer，故背压期间候选不会被抢走。ROB 接收 disp_fire、disp_count 和 disp_rob；IQ 接收包内类别生成的 disp_prepare 和叠加 fire 的逐 lane disp_valid；LSU 接收同样的访存 lane 事件。无效 lane 载荷不消费，不为 LSU 或 IQ 传递全核 count 和其他模块的投影。

Rename 按包内顺序读取临时推测 RAT 的源映射；对非零 rd，先把更新前映射记录为该 lane 的 `old_pdst`，再分配最低编号空闲 pdst 并更新临时 RAT；无目的写 lane 的 `old_pdst=0`。后续 lane 读取更新后的映射。ps1/ps2=0 时源总是就绪。只有 fire 才更新推测 RAT、空闲表和分配状态。offer 保留的 checkpoint 编号仍处于空闲状态，对应 snapshot 可提前写入；每个镜像包含该分支及同包更老 lane 的 RAT 更新，在 fire 边沿发布有效位。提前写入不发布 cp_alloc_valid、不改变 snapshot_valid，也不回收或分配物理寄存器。offer 中编号保持，源就绪侧带读取实时 ready 表并合入当拍唤醒；若源来自同包较老 lane 的新目的则未就绪。

所有 cp_alloc_valid 均包含统一 fire，非控制流 lane 无事件。cp_alloc_payload 的身份为 `{(rob_tail+lane) mod R}`；按包内控制流次序选 cp_alloc_id。资源不足时可派遣更短前缀，不能派遣没有 checkpoint 的分支。

不维护 committed RAT，只保留推测 RAT（sRAT）。ROB 为每条写寄存器指令保存 old_pdst；退休时 Rename 直接释放该 old_pdst（按 lane 从老到新依次释放，支持同拍同物理寄存器多次释放）。reg_commit_valid 仅在该退休 lane 写寄存器时为 1，reg_commit_payload 仅携带该 lane 的 old_pdst，其余 lane 无事件。

当拍释放的物理寄存器和队列槽从下一拍起参与分配，不做容量组合穿透。复位推测 RAT 为 xN→pN；p0..p31 就绪，其他物理寄存器空闲且未就绪。p0 固定为零且不分配为目的。

### 6.3 Checkpoint 快照与恢复

branch_ctrl 保存 K 项元数据 valid/tag/pred_npc；Rename 按同一个 cp_id 保存推测 RAT 的 x1..x31 快照和 P 位 younger_alloc 位图，x0 恒为 p0。双方 checkpoint 有效位复位为空。分配 cp_id 时，在完成该分支自身重命名更新后保存快照，因此包含其 JAL/JALR 链接目的，不包含同包更年轻更新；快照不保存 free/ready 表。

每次非零 pdst 分配，都将该位加入所有更老且仍有效 checkpoint 的 younger_alloc。同拍按 lane 顺序处理：先为当前指令更新既有更老位图，若其是分支，再建立新快照并将新位图清零；之后的 lane 才进入这个新位图。没有 fire 的 offer 不改变快照或位图。

cp_release_mask 在解析后回收元数据与对应快照；正确预测立即释放其 checkpoint，不等退休。误预测在 squash_valid 当拍通过 restore_cp_id 读取尚未释放的快照及位图：推测 RAT=该快照，free_next=current_free | younger_alloc | 当拍较老退休释放位，ready 只清 younger_alloc 中的目的位，其余 ready 保留并合入存活写回。不能恢复历史 free/ready 表，否则会撤销较老提交回收或丢失晚到完成。

触发 checkpoint 和所有更年轻 checkpoint 同拍释放；更老未解析 checkpoint 保留。更老 checkpoint 的位图可保留已被内层 squash 回收的位，这些编号后续再分配时仍属于其年轻范围；p0 从不加入位图。恢复边沿先消费触发快照，再应用释放掩码，不能因 release 而漏掉恢复数据。

### 6.4 非控制流的错误预测

在形成 offer 时扫描到首个非控制流且 pred_npc!=PC+4 的指令，将前缀截到该指令。`front_redirect_pc=PC+4`，valid 仅在该前缀 fire 时产生；Rename 不读取或计算 generation。branch_ctrl 接收该事件后统一生成 `new_gen=current_gen+1` 和 `fetch_redirect`。

纠正保留这个前缀的全部正常重命名、checkpoint 和派遣更新，只清除 Fetch 及 Rename 的年轻后缀/输入缓冲；不截断 ROB、不恢复 RAT。与更老执行期恢复同拍时，squash_valid 禁止 fire，因此不产生 front_redirect。disp_ready 不能由 fetch_redirect_valid 门控，否则前端纠正与自己的派遣构成组合环。

## 7. IQ、发射与 PRF

IQ 仅接收自己的派遣投影及 `wake_valid[I+4]/wake_pdst[I+4]`（模块端口宽度参数仍名为 WB_WIDTH；I+2 个真实完成口加 ALU、Load 两个提前唤醒口，宽路配置将提前唤醒置零），不接收结果数据、ROB 完成信息、控制流目标或退休信息。各 IQ 存储本地有效位与源就绪位，每拍给出至多 I 个按 ROB 年龄排序的就绪候选。Rename 的物理 ready 表在派遣时清新目的位，仅由 I+2 个真实完成口置对应目的位；IQ 在派遣时采样源就绪，随后按源物理编号匹配唤醒。

候选接口为 cand_valid[I]、cand_uop[I]、cand_take[I]。iq_alu/iq_mem 新增 PIPELINED（模块默认 1）。PIPELINED=1 保留候选寄存器队列，IQ 在搬入该级时释放槽；PIPELINED=0 直接输出 core 的按年龄候选，cand_take 在接收边沿释放 IQ 槽。student_top 当前使用 0。背压保留未消费项；squash 由调度器按年龄屏蔽年轻执行有效位发布，take 可消费被取消项；队列在恢复边沿清除年轻项。已有项的当拍 wake 可参与候选选择，未就绪的源仍按物理编号匹配；同龄时按槽号选择，同一条指令不重复发射。

issue_sched 合并两组候选，按 ROB 年龄选择可容纳的最老项，同龄时按 ALU 候选槽号升序、再按 MEM 候选的顺序选择；后续发射 lane 排除先前 lane 已选的候选和已占用的执行入口。每拍总 take 数不超过 I。它保留 I 个 ALU 入口、一个 MULDIV 入口、一个 AGU 入口，各深度 1；为空或本拍被执行单元接收的入口可接收新项。ALU IQ 的 op=38..45 投影到 mul_exec_t，其他项投影到 alu_exec_t；MEM IQ 投影到 mem_exec_t。

PRF 有 2I 个组合读口，选择序号 k 使用读口 2k/2k+1，操作数与执行投影一起在 take 边沿锁存。读口仍按 8 项分 bank。新增 BYPASS_WRITE（模块默认 0）；student_top 使用 1，当拍 forward_valid/pdst 匹配读地址时返回 forward_value，使已完成但尚未获得写回端口的生产者也能提供同拍唤醒值。FORWARD_WIDTH 默认等于 WB_WIDTH，顶层设为 I+2。多个转发口匹配时最后一个 lane 优先；p0 始终读零且不写。派遣与唤醒同拍仍记录源就绪，新派遣项最早下一拍参与选择。

PRF 复位只需将 p1..p31 的初始架构值设零；p0 可直接用常量实现，其他数据不复位。checkpoint 恢复只处理被 squash 的目的和映射，不清 PRF 数据。

## 8. 执行与定向完成

### 8.1 执行单元

ALU 新增 PIPELINED（模块默认 1）。PIPELINED=1 使用一项结果缓冲，接收请求后最早下一拍 result_valid。student_top 当前使用 PIPELINED=1；可选 PIPELINED=0 时：结果缓冲为空时，当前执行入口的结果直接输出到完成/转发通路；写回背压时在接收请求边沿保存结果，之后载荷保持。缓冲满且本拍消费时可同时接收后继，但后继结果先进入缓冲，不能一拍产生两次完成。两种模式的分支解析均在请求接收边沿锁存并在下一拍发布，不依赖当拍 squash 或 WB ready；直通结果已消费也不丢失或重复解析。ALU 根据 op 使用寄存器值、PC 或 imm，计算 32 位结果。NOP 正常产生一次完成，pdst=0。

分支实际下一 PC：条件成立为 PC+imm，否则 PC+4；JAL 为 PC+imm，JALR 为 (rs1+imm)&~1。JAL/JALR 的寄存器结果为 PC+4。实际下一 PC 仅进入独立 branch_resolve 通路，不通过普通完成包或 ROB 退休传递。整数结果截断为 32 位，移位量使用低 5 位，有符号比较和右移使用有符号解释。

乘除单元一次处理一条指令，结果保持至接收。乘法使用组合 `a*b`，在请求接收沿锁存结果，下一周期 `result_valid` 有效；普通除法采用每拍一位的 32 轮迭代，在请求被接收后第 32 个时钟沿产生结果。除零及有符号溢出特例可在请求接收沿直接生成结果。结果有效且被接收的同一时钟沿可接收下一条请求；等待结果期间背压执行入口。结果只携带完整 ROB 身份、pdst 和 value，不携带下一 PC。

| 情况 | 结果 |
|---|---|
| MUL | 乘积低 32 位 |
| MULH / MULHSU / MULHU | 分别按有符号×有符号、有符号×无符号、无符号×无符号求 64 位乘积的高 32 位 |
| DIV/DIVU 除零 | `0xffffffff` |
| REM/REMU 除零 | 原被除数 |
| DIV `0x80000000 / 0xffffffff` | `0x80000000` |
| 同上 REM | 0 |
| 正常有符号除法 | 商向零截断，非零余数符号与被除数一致 |

每个 ALU 在接收控制流请求后下一拍输出一次 `resolve_valid/resolve_payload:branch_resolve_t`，携带 tag、cp_id、分支 PC、is_conditional、实际 taken、target 和真实 npc；独立寄存器保留一次性解析待发位。事件不等待 result_ready，下一拍清除解析待发位，即使普通结果继续背压或已由直通路径消费也不重复解析。候选取自已锁存的解析载荷/有效位，不组合依赖本次 squash 或 WB ready。

branch_ctrl 同时接收 I 条解析事件，以有效 checkpoint 的 cp_id/tag 匹配并比较 pred_npc。在多条误预测中选择按恢复前 rob_head 计算的最老者；该分支及更老解析均生效，更年轻解析被 squash。匹配正确的存活分支释放 checkpoint，所有存活解析同时产生训练事件；更年轻解析不训练。

IQ、发射入口、ALU/MULDIV、AGU、LSU 完成缓冲按第 12 节取消年轻项；较老运算及触发分支本身不被清空。长延迟乘除只有其身份比恢复边界年轻时才终止。解析不等于写回或退休：JAL/JALR 的结果可在恢复之后才写 PRF。

### 8.2 完成仲裁与消费者

wb_arb 接收 I 路 ALU、一条乘除和一条 LSU 结果，统一使用 result_t，不携带控制流目标。源编号 0..I-1 为 ALU、I 为 MULDIV、I+1 为 LSU。WB 直接接收 squash_valid/tag 和 rob_head，按周期开始时的 head 屏蔽本拍 squash 的年轻 done/write，不向 ROB 发起存活查询。FILTER_AFTER_SELECT 默认 0（先过滤再仲裁）；顶层设 1（先仲裁再过滤输出），使源 ready 与恢复无组合依赖。

此筛选依赖第 2 节既有的内部生命周期约定：每条指令只产生一次被接收的完成，接收后源清除该结果；被 squash 的内部工作在该边沿取消，之后不能重现旧结果。LSU 先按 LQ 完整身份过滤外部迟到响应，再产生结果。因此待仲裁结果均属于周期开始时活跃的 ROB 项，只需处理本拍 squash 的年龄边界。

每源每拍至多占一个 W 路轮询 lane，指针移至最后接收源之后。FILTER_AFTER_SELECT=0 时仅存活结果参与仲裁，年轻结果直接 ready 丢弃。FILTER_AFTER_SELECT=1 时所有原始有效源参与仲裁；被选中的年轻项仍 ready，但 done/write 均为零，未选中的年轻项由 FU 在恢复边沿自行清除。没有选择则指针保持。

轮询指针只需 IDX(I+2) 位，复位为零；索引回绕使用比较与减法，避免把 32 位有符号取模综合进仲裁路径。端口、每 lane 的轮询顺序和指针更新时机不变。

| 输出 | 接收方 | 内容 |
|---|---|---|
| done_valid[W]、done_tag[W] | ROB | 仅 rob_tag_t |
| write_valid[W]、write_pdst[W]、write_value[W] | PRF | 存活完成且 pdst!=0 时写入 |
| write_valid[W]、write_pdst[W] 的分支线 | Rename、两 IQ 的 wake 端口 | 仅物理目的和有效位，不增加结果数据 |

wb_arb 新增整数参数 `PIPELINED`（默认 0，取 0/1）。独立模块默认维持组合广播；student_top 当前使用 PIPELINED=0，当拍仲裁并广播；选择 PIPELINED=1 时，完整 `{tag,pdst,value}` 先锁存一拍，下一拍广播。该级每拍接收 W 个结果，不增加输出 ready；在输出时再次按当前 squash 年龄边界过滤，避免暂存的年轻结果越过恢复。cursor 仍在 FU 结果被接收时前进，ALU 解析事件仍独立于该流水级。完成和 PRF 写在同一广播接收边沿发生；顶层唤醒独立来自当前 FU 结果，可早于写回接收。NOP、无链接分支或 Store 仍使用完成 lane，pdst=0 不影响 done。WB 不因发生恢复而整体关闭；触发分支及更老结果仍可当拍写入，更年轻结果不能产生 done 或真实 PRF 写；其原始唤醒只影响随后被取消的年轻依赖状态。

## 9. ROB 与退休

ROB 每项保存 `rob_alloc_t`（其中含 old_pdst/kind/sq_id）、done 和 Store 授权/响应状态，不保存原指令、PC、预测值、实际目标、mispred 或 checkpoint 副本。头尾索引仍为 RW 位。ROB 不输出 generation 占用向量。

非 Store 指令（含控制流、Load）每拍退休至多 C 条连续已完成前缀；遇到未完成项或 Store 停止，较老前缀先退休。控制流与其他非 Store 指令共用退休宽度，不截断前缀，也不再触发恢复；实际目标的解析事件最迟在其退休边沿处理。Store 仍在头部单独授权、等待写完成后单独退休。当拍完成最早下一拍退休；squash 当拍的退休前缀不得包含边界之后的年轻项。

Store 在头部且执行完成后产生一次 st_start_valid/st_start_id 事件；完成条件包括已记录的 completed 位以及本拍 WB 的匹配 done_tag/valid，允许授权与完成接收同拍。未被 WB 接收的 FU 结果不能授权写。LSU 的 SQ 已预留且上一个授权 Store 已完成，故无需 ready 或往返 ROB ID。收到 st_done_valid 且头部 Store 已授权时 ROB 可在同一边沿退休。更年轻分支解析时，头部 Store 可能正在等待 AW/W/B，这项授权和等待状态必须保留。

ROB 只向 Rename 发出写寄存器退休 lane 的 reg_commit_valid/old_pdst，允许空洞；`old_pdst!=0` 即表示该项存在架构寄存器写。退休时 Rename 直接释放 old_pdst；LSU 不接退休广播。

squash 边界 b 来自尚未退休的解析分支。按周期开始时 head 计算 keep_count=age(b)+1，令 tail=(b.index+1) mod R，清除其后年轻项。保留前缀的同拍退休 m 项仍生效：head 正常前移，count=keep_count-m。ALU 结果直通时，触发分支可在上一边沿已写回，因此允许它与自身解析/恢复在同一边沿正常退休；年龄与保留边界仍按恢复前 head 计算。所有有效的较老 done/Store 完成继续更新保留项。squash 当拍不接新派遣。ROB 不向 branch_ctrl 发退休恢复事件。

ROB 接收 done_valid/done_tag 时在本地匹配当前占用区间和 squash 边界，仅更新匹配且存活项的 done，不向 WB 返回组合筛选结果；不比较目的值。这样同一 ROB index 的存活指令正确完成。

## 10. LSU 与槽位回收

LSU 由派遣事件按指定 mem_id 分配 LQ/SQ，保存完整 ROB 身份；LQ 还保存 pdst。AGU 请求携带 tag、mem_op、mem_id、base/imm/data，便于其发射缓冲独立按年龄 squash；pdst 只从队列记录取得。

AGU 等待所需源值就绪，计算 effective_addr=base+imm，Store 地址和数据一起就绪。访存大小、无符号 Load 由 mem_op 在本地推导。字节/半字/字按自然对齐前提处理：

```text
aligned_addr = effective_addr & 0xfffffffc
offset       = effective_addr[1:0]
nbytes       = 1 << size
strb         = ((1 << nbytes) - 1) << offset
write_data   = data << (8 * offset)
load_bits    = read_data >> (8 * offset)
```

size 为本地译码结果，不是流水接口字段。Load 按大小截取并符号/零扩展。RAM 门控只比较 effective_addr[31:28]==0；自然对齐访问不会跨越对齐字或 RAM 边界，无对齐检查或末字节范围加法器。

恢复边沿允许暂存的 RAM Load 与 DCache 握手；squash 清除年轻槽后，旧响应按原 {gen,id} 过滤并只归还额度。尚未接受的年轻 offer 在恢复边沿取消。RAM Load 扫描更老 SQ：旧 Store 地址未知或同字节重叠且未完成写时等待；地址不同或字节掩码不相交可发送。LSU 从 branch_ctrl 接收 `current_gen`；形成新的 ld_req offer 或空缓冲直通握手时，把当时的 `current_gen` 锁存在该 LQ 槽中，直通握手还在同一边沿设置等待响应状态。ld_req 为保持型通道，携带 `{gen,id}`，DCache 接收后计入读额度；ld_rsp 是无 ready 事件，每次事件均减少读额度。只有该 id 的 LQ 仍等待响应、`{gen,id}` 与该槽记录匹配且其 tag 不属于本拍 squash 范围时才存入数据；不匹配的响应只归还额度并丢弃。WB 背压不会占用桥内响应缓冲。

非 RAM Load 不发请求，在其 LQ 产生零值并标记数据就绪，不占读额度，不等待 Store 消歧或外部响应。这使任意错误路径 Load 不访问 MMIO，也不会等待不存在的结果。

LSU 的 PIPELINED 控制请求缓冲，RESULT_PIPELINED 控制结果缓冲（独立模块默认继承 PIPELINED），student_top 两者均使用 1。从数据就绪的 LQ、当拍身份/年龄匹配的 Load 响应、地址/数据就绪或本拍执行 AGU 的 SQ 中选最老且完成未发送的项。载荷从队列记录取 tag/pdst，Store 的 pdst=0；当拍响应按 LQ 的 op/offset 扩展数据。RESULT_PIPELINED=1 使用一项寄存器结果缓冲，响应胜出时直接写该缓冲。RESULT_PIPELINED=0 在结果缓冲为空时组合输出所选结果，WB 接收则不额外暂存，WB 背压则锁存并保持；缓冲满且本拍消费时，后继只能进入缓冲。未胜出或缓冲背压的响应仍保存到 LQ。完成被 wb_arb 接收后，Load 立即释放 LQ；Store 标记执行完成已发送并继续保留 SQ。LQ 不必等退休，已返回的读事务不存在迟到响应。

RAM Load 的 AGU 同拍参与读请求选择，使用当前地址/op 检查旧 Store 依赖。PIPELINED=1 在同一边沿锁存地址与请求 offer，下一拍可握手；PIPELINED=0 在 offer 为空且读额度可用时直接发出选中 Load 的请求，Cache 背压或额度不足时在边沿锁存 offer，后续保持原地址/gen/id。已有 offer 本拍握手时允许同时补入下一项，已接受或已暂存的 Load 不会再次选择。两种模式都保留未知地址或重叠 Store 的阻塞、RAM 门控及 squash 年龄过滤，不进行 Store 转发或投机消歧。

SQ 只接收 ROB 头部 st_start_id 授权。默认 BUFFER_STORES=1 时授权进入已提交 FIFO，下一拍向 ROB 应答 RAM Store；SQ 和数据保留到 DCache 实际完成，已授权写按序排空。MMIO 不提前应答 ROB，DCache 先排空脏行再透传 AW/W/B，等待自身 B 后才完成。BUFFER_STORES=0 保留原单项授权直通模式。st_req 的 addr/data/strb 在背压期间保持，握手后不得重复发出；真实写完成解除 Load 依赖并释放 SQ。详情与 EARLY_STORE 数据等待协议见第 20.2 节。

错误路径 Store 不会取得头部授权，任意地址仅保留在 SQ。正确路径合法退出 SW 也遵守相同授权及 AW/W/B 协议。LSU 不检查授权地址或标签的一致性，不为冗余核对传递副本。

squash 只清除年轻 LQ/SQ、年轻未接受请求和年轻完成缓冲，保留较老队列、消歧依赖和授权写状态。桥已接受的年轻读继续返回，LQ 槽可在下一拍复用（发出新请求时锁存新 generation）；LOAD_OUTSTANDING 计数不清零，旧读返回时照常归还额度。较老 Store 和它阻塞的较老 Load 关系保留；已移除的年轻 Store 不再参与消歧。

恢复当拍同时处理 R/B 事件：`{gen,id}` 不匹配的 R 只归还额度，匹配的 R 更新其 LQ；较老授权 Store 的响应正常释放 SQ；默认缓冲模式仅 MMIO 的真实响应产生 st_done，RAM 不重复应答 ROB。不能因 generation 已切换而丢弃写完成。

## 11. AXI 桥

### 11.1 读通路

ICache 的 IF 与 DCache 的 LD 填充请求为独立保持型通道，分别使用 IF_ID_WIDTH 和 DC_WORD_W+2 位 id（预取关闭时 LD 为 DC_WORD_W），并携带请求所属 generation（`{gen,id}`）；外部 AXI 端口不增加 ID。共享最多 AXI_RD_OUTSTANDING 笔请求；两者同时有效时轮询，复位 IF 优先，每次接收后优先另一方，每拍至多接受一个。桥本地记录 source、generation、对应槽号和 AR 所需地址。LD 的 generation 来自原 Load 发出时锁存的值，不强制改成当前 generation。

已接受请求按顺序发送 AR，arvalid/addr 保持至 arready。请求描述符保留到对应 R 握手；AXI 无 ID，R 匹配最老的已发 AR 请求。同拍刚握手的 AR 最早下一拍才接受其 R，符合外部从机延迟约定。

ICache/DCache 填充缓冲为每个读预留了接收槽，因此不提供 if_rsp_ready/ld_rsp_ready，也不需要桥内返回数据队列。存在已发 AR 的队首事务时桥接收 R，在握手拍向对应客户端发送一次 `{gen,id,data}` 事件并释放桥槽。无论身份是否已被 squash 都返回事件，由客户端按 `{gen,id}` 匹配：ICache 按物理填充身份写整行缓冲，DCache 按填充字号写 SRAM；DCache 返回给 LSU 的 {gen,id} 仍按 LQ 身份匹配。桥不按当前 generation 过滤，也不因前端恢复而阻塞 R。

### 11.2 写通路

桥有 AXI_WR_OUTSTANDING 个写槽（模块默认 16），st_req 为 addr/data/strb 保持型通道，不携带事务 ID。AW、W 各有顺序发送指针和未发送计数，独立驱动并保持至握手；write_count 包含等待发送或等待 B 的事务。仅当最老事务的 AW、W 都已握手时接收 B，`st_rsp_valid=bvalid&&bready` 为无载荷完成事件，并释放一个槽。队列满时背压；支持 AW/W 速度不同、连续请求及同拍入队/出队，保持 AXI4-Lite 无 ID 的顺序响应约定。CPU 集成时其写客户端为 DCache。

### 11.3 跨 generation 的事务履约

桥不接收 run/kill/restore/squash，也不提供恢复用 idle。即使请求所属路径已经失效，已接受请求仍按原顺序完成 AR/R 或 AW/W/B；已展示的 VALID 保持到握手。新路径可使用剩余容量，不需要等整个桥排空；总线队列满仍会产生正常背压。

写请求不增加 generation 字段：它来自 DCache 的已提交脏数据写回或已授权 MMIO Store，均不可 squash。RAM Store 的 ROB 项在 Cache 更新完成后退休；MMIO 等待所有脏写回和自身 B 完成。

## 12. 执行期恢复与 generation

### 12.1 Generation 方案

branch_ctrl 维护全局 `current_gen[GEN_WIDTH-1:0]`，默认 `GEN_WIDTH=16`，复位为 0。**每次发生实际 redirect**（分支误预测或 `front_redirect` 前端纠正）时组合得到 `new_gen=current_gen+1`，在恢复边沿更新 `current_gen<=new_gen`，并把同一个 `new_gen` 放入 `fetch_redirect`。generation 只用于异步读请求的身份匹配：`ic_req/ic_rsp` 携带取指包身份，`if_req/if_rsp` 携带物理填充身份，`ld_req/ld_rsp` 携带 Load 身份。

- Load 请求发出后在槽中锁存 generation，所有响应归还物理额度，匹配才写槽。Fetch 额度只统计当前路径包；ICache 在 redirect 取消旧包，但物理填充继续按原身份完成，不能按当前前端 generation 丢弃填充响应。
- 约定从任一读请求被 bridge 接收到其响应返回期间，发生的实际 redirect 次数严格小于 `2^16`，因此 16 位 generation 不会发生 ABA 回绕碰撞。该假设约束的是旧请求存活期间的 redirect 次数，与同时 outstanding 的读事务数量没有直接关系。
- 不设 epoch 池、`recovery_epoch`、`epoch_free`、`epoch_alloc_id`、`rob_epoch_busy`、`bridge_epoch_busy`。ROB tag 只含 rob_id/index，后端不携带 generation。

cp_alloc_id[D] 给出最低编号的空闲 checkpoint。每个 offer 为各控制流指令分配一个 checkpoint；末尾若有普通指令前端纠正，不额外占用 checkpoint。分配只在统一 fire 的 cp_alloc/front_redirect 事件生效；预览数量为 min(容量,输出 lane 数)，其余 lane 不消费。

分支 checkpoint 不预留 generation。误预测和 `front_redirect` 都由 branch_ctrl 统一计算 `new_gen=current_gen+1`，同拍用于 `fetch_redirect.new_gen`，并在边沿写回 `current_gen`。没有可用 checkpoint 时，Rename 在相关指令之前背压；已经派遣的分支解析仍能立即重定向。

### 12.2 解析与控制接口

| 信号 | 生产者 → 消费者 | 含义 |
|---|---|---|
| train_valid[I]/train_payload[I] | branch_ctrl → branch_predictor | bp_train_t 事件，过滤并按 ROB 年龄从老到新排列 |
| resolve_valid[I]/resolve_payload[I] | ALU → branch_ctrl | 一次性 branch_resolve_t 候选，独立于 WB |
| squash_valid | branch_ctrl → ROB、Rename、IQ、issue_sched、FU、LSU、wb_arb | 执行期局部恢复事件 |
| squash_tag | branch_ctrl → ROB、IQ、issue_sched、FU、LSU、wb_arb | 最老误预测分支身份，供年龄比较；Rename 只使用 restore_cp_id |
| restore_cp_id | branch_ctrl → Rename | squash 当拍读取的快照编号 |
| cp_release_mask[K] | branch_ctrl → Rename | 本拍解析/清除的 checkpoint；恢复读取优先于释放 |
| fetch_redirect_valid/payload | branch_ctrl → Fetch；valid 同时送 ICache | 目标 PC 与新 generation，来自执行期恢复或前端纠正 |

控制器对每个解析候选匹配 checkpoint 的有效位及完整 tag。匹配的误预测按恢复前 rob_head 选择最老者 b；产生 squash(b)、restore_cp_id、fetch_redirect 和新 generation（`current_gen+1`）。cp_release_mask 同时包含 b、更年轻 checkpoint，以及本拍正确解析且不年轻于 b 的 checkpoint。没有误预测时只释放正确解析项。

执行期恢复优先于 front_redirect；前者通过 squash_valid 取消当拍新派遣，所以两者不会共同生效。没有执行期恢复时，front_redirect 与该 offer 的 cp_alloc 同拍生效；已在该拍形成或接受的旧请求保持原 generation，新 generation 从恢复边沿后用于新建 Fetch 槽以及之后新发出的 Load 请求。cp_release 不阻止不相关的正常派遣，但释放出来的资源下一拍才可选。

控制流解析候选来自 ALU 已锁存状态，不依赖 squash；控制器不依赖 ROB 的 done 或 write_valid，WB 按恢复广播和周期开始时的 rob_head 单向筛选结果。因此执行期重定向、结果筛选与写回不构成组合环。

### 12.3 年龄边界与事件优先级

恢复时 `younger(tag,b) = age(tag.index) > age(b.index)`，使用边沿前同一个 rob_head；仅用于当前活跃内部工作。外部迟到响应先由 ICache/LSU 按完整 `{gen,id}` 身份匹配，Fetch 仅接收未取消的包响应；内部结果按第 8.2 节的生命周期约定保持活跃，再比较年龄，不能把已失效旧标签直接当成当前槽的年龄。generation 既不表示年龄，也不是“只允许当前 generation 执行”的全局开关。

| 模块 | 恢复行为 |
|---|---|
| Fetch | 清全部旧前端槽/offer/输出，消费 branch_ctrl 给出的目标 PC/new_gen，更新本地 fetch_gen，清当前路径取指槽额度 |
| ICache | 取消命中响应与等待包，保留有效缓存和物理填充，继续履行填充读 |
| Rename | 清未派遣缓冲，按 checkpoint 恢复推测 RAT/回收年轻目的；继续接收较老退休和存活唤醒 |
| ROB | 保留至 b，尾部截断；较老同拍退休、完成和 Store 回报继续生效 |
| IQ/issue_sched | 仅删除年轻项/入口，屏蔽年轻 take/执行握手，允许存活候选继续发射 |
| ALU/MULDIV | 仅取消年轻运算和结果，保留 b 的链接结果及更老长延迟运算 |
| LSU | 仅清年轻队列/请求/结果；保留较老读写和授权状态，所有响应仍归还额度 |
| wb_arb/PRF | WB 按 squash 年龄边界屏蔽年轻完成，PRF 只接收存活写入；没有全局清空或恢复时全局禁写 |
| AXI bridge | 不参与 squash，保持协议履约并接收有额度的新请求 |

恢复当拍禁止新派遣，空闲槽及回收物理寄存器从下一拍使用；存活的正常事件不被整体冻结。Fetch 在恢复边沿设置 PC，下一拍可建立正确路径请求（携带新 generation）。没有 DRAIN/RESTORE 等待状态或全模块确认向量，checkpoint 恢复在该边沿完成。

### 12.4 必要跨周期场景

## 13. 模块端口声明

以下声明仅定义连接，模块体留空。派生位宽由架构参数计算，不独立覆盖。各类型的嵌套 rob_tag_t 按第 3 节布局打包。

### 13.1 `student_top`

```systemverilog
module student_top #(
    parameter integer ISSUE_WIDTH = 1,
    parameter integer DISPATCH_WIDTH = 1,
    parameter integer WB_WIDTH = 2,
    parameter integer COMMIT_WIDTH = 2,

    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 48,
    parameter integer IQ_ALU_DEPTH = 7,
    parameter integer IQ_MEM_DEPTH = 4,
    parameter integer LQ_DEPTH = 4,
    parameter integer SQ_DEPTH = 8,
    parameter integer FETCH_QUEUE_DEPTH = 16,
    parameter integer IFETCH_OUTSTANDING = 8,
    parameter integer ICACHE_SIZE_BYTES = 1024,
    parameter integer ICACHE_WAYS = 2,
    parameter integer ICACHE_LINE_BYTES = 32,
    parameter integer DCACHE_SIZE_BYTES = 16384,
    parameter integer DCACHE_WAYS = 2,
    parameter integer DCACHE_LINE_BYTES = 64,
    parameter integer DATA_PREFETCH = 1,
    parameter integer BP_ENABLE = 1,
    parameter integer BTB_ENTRIES = 32,
    parameter integer BHT_ENTRIES = 256,
    parameter integer LOAD_OUTSTANDING = 4,
    parameter integer AXI_RD_OUTSTANDING = 16,
    parameter integer CHECKPOINT_DEPTH = 4,
    parameter integer GEN_WIDTH = 16,
    parameter [31:0] RESET_PC = 32'h00000000
) (
    input logic clock, reset,
    output logic [31:0] araddr,
    output logic arvalid,
    input logic arready,
    input logic [31:0] rdata,
    input logic [1:0] rresp,
    input logic rvalid,
    output logic rready,
    output logic [31:0] awaddr,
    output logic awvalid,
    input logic awready,
    output logic [31:0] wdata,
    output logic [3:0] wstrb,
    output logic wvalid,
    input logic wready,
    input logic [1:0] bresp,
    input logic bvalid,
    output logic bready
);
```

### 13.2 `fetch`

```systemverilog
module fetch #(
    parameter integer OUTPUT_BYPASS = 0,
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer FETCH_QUEUE_DEPTH = 16,
    parameter integer IFETCH_OUTSTANDING = 8,
    parameter integer ICACHE_LINE_BYTES = 32,
    parameter integer GEN_WIDTH = 16,
    parameter [31:0] RESET_PC = 32'h00000000,
    parameter integer FIDW = (FETCH_QUEUE_DEPTH > 1) ? $clog2(FETCH_QUEUE_DEPTH) : 1,
    parameter integer DCW = $clog2(DISPATCH_WIDTH + 1),
    parameter integer FETCH_BITS = 96,
    parameter integer FETCH_REDIRECT_BITS = 32 + GEN_WIDTH,
    parameter integer IC_REQ_BITS = GEN_WIDTH + FIDW + DCW + 32,
    parameter integer IC_RSP_BITS = GEN_WIDTH + FIDW + DCW + 32*DISPATCH_WIDTH
) (
    input logic clock, reset,
    input logic fetch_redirect_valid,
    input logic [FETCH_REDIRECT_BITS-1:0] fetch_redirect_payload,
    output wire [31:0] lookup_pc,
    input logic [DISPATCH_WIDTH-1:0] pred_taken,
    input logic [DISPATCH_WIDTH*32-1:0] pred_npc,
    output logic ic_req_valid,
    input logic ic_req_ready,
    output logic [IC_REQ_BITS-1:0] ic_req_payload,
    input logic ic_rsp_valid,
    input logic [IC_RSP_BITS-1:0] ic_rsp_payload,
    output logic fetch_valid,
    input logic fetch_ready,
    output logic [DCW-1:0] fetch_count,
    output logic [DISPATCH_WIDTH*FETCH_BITS-1:0] fetch_packet
);
endmodule
```

### 13.3 `decode`

```systemverilog
module decode #(
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer DCW = $clog2(DISPATCH_WIDTH + 1),
    parameter integer FETCH_BITS = 32 + 32 + 32,
    parameter integer DECODE_BITS = 32 + 32 + 6 + 5 + 5 + 5 + 32
) (
    input logic fetch_valid,
    output logic fetch_ready,
    input logic [DCW-1:0] fetch_count,
    input logic [DISPATCH_WIDTH*FETCH_BITS-1:0] fetch_packet, // fetch_packet_t × D
    output logic decode_valid,
    input logic decode_ready,
    output logic [DCW-1:0] decode_count,
    output logic [DISPATCH_WIDTH*DECODE_BITS-1:0] decode_uop // decoded_uop_t × D
);
endmodule
```

### 13.4 `rename`

```systemverilog
module rename #(
    parameter integer DIRECT_RENAME = 0, CHECKPOINT_RAM = 0,
    parameter integer CHECKPOINT_BANKED = 0,
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer WB_WIDTH = 2,
    parameter integer COMMIT_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer IQ_ALU_DEPTH = 16,
    parameter integer IQ_MEM_DEPTH = 16,
    parameter integer LQ_DEPTH = 8,
    parameter integer SQ_DEPTH = 8,
    parameter integer CHECKPOINT_DEPTH = 4,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1,
    parameter integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1,
    parameter integer CIDW = (CHECKPOINT_DEPTH > 1) ? $clog2(CHECKPOINT_DEPTH) : 1,
    parameter integer MIDW = (LIDW > SIDW) ? LIDW : SIDW,
    parameter integer DCW = $clog2(DISPATCH_WIDTH + 1),
    parameter integer ROB_CW = $clog2(ROB_DEPTH + 1),
    parameter integer AIQ_CW = $clog2(IQ_ALU_DEPTH + 1),
    parameter integer MIQ_CW = $clog2(IQ_MEM_DEPTH + 1),
    parameter integer LQ_CW = $clog2(LQ_DEPTH + 1),
    parameter integer SQ_CW = $clog2(SQ_DEPTH + 1),
    parameter integer CCW = $clog2(CHECKPOINT_DEPTH + 1),
    parameter integer TAG_BITS = RW,
    parameter integer DECODE_BITS = 117,
    parameter integer ROB_ALLOC_BITS = PW + 2 + SIDW,
    parameter integer ALU_IQ_BITS = TAG_BITS + CIDW + 6 + PW + PW + PW + 64,
    parameter integer MEM_IQ_BITS = TAG_BITS + 3 + MIDW + PW + PW + 32,
    parameter integer MEM_ALLOC_BITS = 1 + MIDW + TAG_BITS + PW,
    parameter integer CP_ALLOC_BITS = CIDW + TAG_BITS + 32,
    parameter integer REG_COMMIT_BITS = PW
) (
    input logic clock, reset, squash_valid,
    input logic [CIDW-1:0] restore_cp_id,
    input logic [CHECKPOINT_DEPTH-1:0] cp_release_mask,
    input logic [CCW-1:0] cp_free,
    input logic [DISPATCH_WIDTH*CIDW-1:0] cp_alloc_id,
    input logic decode_valid,
    output logic decode_ready,
    input logic [DCW-1:0] decode_count,
    input logic [DISPATCH_WIDTH*DECODE_BITS-1:0] decode_uop,
    input logic [ROB_CW-1:0] rob_free,
    input logic [RW-1:0] rob_tail,
    input logic [AIQ_CW-1:0] alu_iq_free,
    input logic [MIQ_CW-1:0] mem_iq_free,
    input logic [LQ_CW-1:0] lq_free,
    input logic [SQ_CW-1:0] sq_free,
    input logic [DISPATCH_WIDTH*LIDW-1:0] lq_alloc_id,
    input logic [DISPATCH_WIDTH*SIDW-1:0] sq_alloc_id,
    output logic disp_valid,
    input logic disp_ready,
    output logic [DCW-1:0] disp_count,
    output logic [DISPATCH_WIDTH*ROB_ALLOC_BITS-1:0] disp_rob,
    output logic [DISPATCH_WIDTH*ALU_IQ_BITS-1:0] disp_alu,
    output logic [DISPATCH_WIDTH*MEM_IQ_BITS-1:0] disp_mem,
    output logic [DISPATCH_WIDTH*MEM_ALLOC_BITS-1:0] disp_lsq,
    output logic [DISPATCH_WIDTH-1:0] disp_src1_ready, disp_src2_ready,
    output logic [DISPATCH_WIDTH-1:0] cp_alloc_valid,
    output logic [DISPATCH_WIDTH*CP_ALLOC_BITS-1:0] cp_alloc_payload,
    output logic front_redirect_valid,
    output logic [31:0] front_redirect_pc,
    input logic [WB_WIDTH-1:0] wake_valid,
    input logic [WB_WIDTH*PW-1:0] wake_pdst,
    input logic [COMMIT_WIDTH-1:0] reg_commit_valid,
    input logic [COMMIT_WIDTH*REG_COMMIT_BITS-1:0] reg_commit_payload
);
```

### 13.5 `prf`

```systemverilog
module prf #(
    parameter integer BYPASS_WRITE = 0,
    parameter integer WORD_RAM = 0,
    parameter integer ISSUE_WIDTH = 2,
    parameter integer WB_WIDTH = 2,
    parameter integer FORWARD_WIDTH = WB_WIDTH,
    parameter integer PRF_SIZE = 64,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1
) (
    input logic clock, reset,
    input logic [2*ISSUE_WIDTH*PW-1:0] rd_addr,
    output logic [2*ISSUE_WIDTH*32-1:0] rd_data,
    input logic [WB_WIDTH-1:0] write_valid,
    input logic [WB_WIDTH*PW-1:0] write_pdst,
    input logic [WB_WIDTH*32-1:0] write_value,
    input logic [FORWARD_WIDTH-1:0] forward_valid,
    input logic [FORWARD_WIDTH*PW-1:0] forward_pdst,
    input logic [FORWARD_WIDTH*32-1:0] forward_value
);
```

### 13.6 `rob`

```systemverilog
module rob #(
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer WB_WIDTH = 2,
    parameter integer COMMIT_WIDTH = 2,
    parameter integer EARLY_STORE_COMMIT = 0,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer SQ_DEPTH = 8,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1,
    parameter integer DCW = $clog2(DISPATCH_WIDTH + 1),
    parameter integer ROB_CW = $clog2(ROB_DEPTH + 1),
    parameter integer TAG_BITS = RW,
    parameter integer ROB_ALLOC_BITS = PW + 2 + SIDW,
    parameter integer REG_COMMIT_BITS = PW
) (
    input logic clock, reset,
    input logic squash_valid,
    input logic [TAG_BITS-1:0] squash_tag,
    input logic disp_fire,
    input logic [DCW-1:0] disp_count,
    input logic [DISPATCH_WIDTH*ROB_ALLOC_BITS-1:0] disp_rob,
    input logic [WB_WIDTH-1:0] done_valid,
    input logic [WB_WIDTH*TAG_BITS-1:0] done_tag,
    output logic [ROB_CW-1:0] rob_free,
    output logic [RW-1:0] rob_tail,
    output logic [RW-1:0] rob_head,
    output logic [COMMIT_WIDTH-1:0] reg_commit_valid,
    output logic [COMMIT_WIDTH*REG_COMMIT_BITS-1:0] reg_commit_payload,
    output logic st_start_valid,
    output logic [SIDW-1:0] st_start_id,
    input logic st_done_valid
);
```

### 13.7 `branch_ctrl`

```systemverilog
module branch_ctrl #(
    parameter integer ISSUE_WIDTH = 2,
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer CHECKPOINT_DEPTH = 4,
    parameter integer GEN_WIDTH = 16,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer CIDW = (CHECKPOINT_DEPTH > 1) ? $clog2(CHECKPOINT_DEPTH) : 1,
    parameter integer CCW = $clog2(CHECKPOINT_DEPTH + 1),
    parameter integer TAG_BITS = RW,
    parameter integer RESOLVE_BITS = TAG_BITS + CIDW + 98,
    parameter integer BP_TRAIN_BITS = 66,
    parameter integer CP_ALLOC_BITS = CIDW + TAG_BITS + 32,
    parameter integer FETCH_REDIRECT_BITS = 32 + GEN_WIDTH
) (
    input logic clock,
    input logic reset,
    input logic [RW-1:0] rob_head,
    output logic [GEN_WIDTH-1:0] current_gen,
    output logic [CCW-1:0] cp_free,
    output logic [DISPATCH_WIDTH*CIDW-1:0] cp_alloc_id,
    input logic [DISPATCH_WIDTH-1:0] cp_alloc_valid,
    input logic [DISPATCH_WIDTH*CP_ALLOC_BITS-1:0] cp_alloc_payload, // cp_alloc_t
    input logic front_redirect_valid,
    input logic [31:0] front_redirect_pc,
    input logic [ISSUE_WIDTH-1:0] resolve_valid,
    input logic [ISSUE_WIDTH*RESOLVE_BITS-1:0] resolve_payload, // branch_resolve_t
    output logic [ISSUE_WIDTH-1:0] train_valid,
    output logic [ISSUE_WIDTH*BP_TRAIN_BITS-1:0] train_payload, // bp_train_t, 从老到新
    output logic [CHECKPOINT_DEPTH-1:0] cp_release_mask,
    output logic squash_valid,
    output logic [TAG_BITS-1:0] squash_tag, // rob_tag_t
    output logic [CIDW-1:0] restore_cp_id,
    output logic fetch_redirect_valid,
    output logic [FETCH_REDIRECT_BITS-1:0] fetch_redirect_payload // fetch_redirect_t
);
endmodule
```

### 13.8 `iq_alu`

PIPELINED=1 时 cand_valid/cand_uop 来自每 lane 一个 candidate_reg；当前顶层 PIPELINED=0，组合选择已就绪项，cand_take 当拍释放原 IQ 槽。

```systemverilog
module iq_alu #(
    parameter integer PIPELINED = 1,
    parameter integer ORDERED_SELECT = 0,
    parameter integer ISSUE_WIDTH = 2, DISPATCH_WIDTH = 2, WB_WIDTH = 2,
    parameter integer ROB_DEPTH = 32, PRF_SIZE = 64, IQ_ALU_DEPTH = 16,
    parameter integer CHECKPOINT_DEPTH = 4,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer CIDW = (CHECKPOINT_DEPTH > 1) ? $clog2(CHECKPOINT_DEPTH) : 1,
    parameter integer AIQ_CW = $clog2(IQ_ALU_DEPTH + 1),
    parameter integer TAG_BITS = RW,
    parameter integer ALU_IQ_BITS = TAG_BITS + CIDW + 6 + PW + PW + PW + 64
) (
    input logic clock, reset, squash_valid,
    input logic [TAG_BITS-1:0] squash_tag,
    input logic [RW-1:0] rob_head,
    input logic [DISPATCH_WIDTH-1:0] disp_valid, disp_prepare,
    input logic [DISPATCH_WIDTH*ALU_IQ_BITS-1:0] disp_uop,
    input logic [DISPATCH_WIDTH-1:0] disp_src1_ready, disp_src2_ready,
    input logic [WB_WIDTH-1:0] wake_valid,
    input logic [WB_WIDTH*PW-1:0] wake_pdst,
    output logic [AIQ_CW-1:0] alu_iq_free,
    output logic [ISSUE_WIDTH-1:0] cand_valid,
    output logic [ISSUE_WIDTH*ALU_IQ_BITS-1:0] cand_uop,
    input logic [ISSUE_WIDTH-1:0] cand_take
);
```

### 13.9 `iq_mem`

```systemverilog
module iq_mem #(
    parameter integer PIPELINED = 1,
    parameter integer ORDERED_SELECT = 0,
    parameter integer EARLY_STORE = 0,
    parameter integer DISPATCH_WIDTH = 2, WB_WIDTH = 2,
    parameter integer ROB_DEPTH = 32, PRF_SIZE = 64, IQ_MEM_DEPTH = 16,
    parameter integer LQ_DEPTH = 8, SQ_DEPTH = 8,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1,
    parameter integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1,
    parameter integer MIDW = (LIDW > SIDW) ? LIDW : SIDW,
    parameter integer MIQ_CW = $clog2(IQ_MEM_DEPTH + 1),
    parameter integer TAG_BITS = RW,
    parameter integer MEM_IQ_BITS = TAG_BITS + 3 + MIDW + PW + PW + 32
) (
    input logic clock, reset, squash_valid,
    input logic [TAG_BITS-1:0] squash_tag,
    input logic [RW-1:0] rob_head,
    input logic [DISPATCH_WIDTH-1:0] disp_valid, disp_prepare,
    input logic [DISPATCH_WIDTH*MEM_IQ_BITS-1:0] disp_uop,
    input logic [DISPATCH_WIDTH-1:0] disp_src1_ready, disp_src2_ready,
    input logic [WB_WIDTH-1:0] wake_valid,
    input logic [WB_WIDTH*PW-1:0] wake_pdst,
    output logic [MIQ_CW-1:0] mem_iq_free,
    output logic cand_valid,
    output logic cand_src2_ready,
    output logic [MEM_IQ_BITS-1:0] cand_uop,
    input logic cand_take
);
```

`iq_mem` 的容量由 IQ_MEM_DEPTH 决定，当前顶层为 4 项。PIPELINED=1 时先搬入单项 candidate_reg；当前顶层 PIPELINED=0，组合选择最老已就绪项，cand_take 当拍释放原 IQ 槽。disp_prepare 表示包中属于此队列的 lane，与 dispatch ready 无关；disp_valid 是实际分配事件，必须为 disp_prepare 的子集。空闲槽按排名匹配，载荷可在握手前准备；valid、源就绪状态仍只在实际派遣时发布。ALU IQ 使用相同准备协议。

### 13.10 `issue_sched`

```systemverilog
module issue_sched #(
    parameter integer ISSUE_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer LQ_DEPTH = 8,
    parameter integer SQ_DEPTH = 8,
    parameter integer CHECKPOINT_DEPTH = 4,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1,
    parameter integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1,
    parameter integer CIDW = (CHECKPOINT_DEPTH > 1) ? $clog2(CHECKPOINT_DEPTH) : 1,
    parameter integer MIDW = (LIDW > SIDW) ? LIDW : SIDW,
    parameter integer TAG_BITS = RW,
    parameter integer ALU_IQ_BITS = TAG_BITS + CIDW + 6 + PW + PW + PW + 32 + 32,
    parameter integer MEM_IQ_BITS = TAG_BITS + 3 + MIDW + PW + PW + 32,
    parameter integer ALU_EXEC_BITS = TAG_BITS + CIDW + 6 + PW + 32 + 32 + 32 + 32,
    parameter integer MUL_EXEC_BITS = TAG_BITS + 3 + PW + 32 + 32,
    parameter integer MEM_EXEC_BITS = TAG_BITS + 3 + MIDW + 32 + 32 + 32
) (
    input logic clock,
    input logic reset,
    input logic squash_valid,
    input logic [TAG_BITS-1:0] squash_tag, // rob_tag_t
    input logic [RW-1:0] rob_head,
    input logic [ISSUE_WIDTH-1:0] alu_cand_valid,
    input logic [ISSUE_WIDTH*ALU_IQ_BITS-1:0] alu_cand_uop, // alu_iq_t
    output logic [ISSUE_WIDTH-1:0] alu_cand_take,
    input logic mem_cand_valid,
    input logic [MEM_IQ_BITS-1:0] mem_cand_uop, // mem_iq_t
    output logic mem_cand_take,
    output logic [2*ISSUE_WIDTH*PW-1:0] rd_addr,
    input logic [2*ISSUE_WIDTH*32-1:0] rd_data,
    output logic [ISSUE_WIDTH-1:0] alu_exec_valid,
    input logic [ISSUE_WIDTH-1:0] alu_exec_ready,
    output logic [ISSUE_WIDTH*ALU_EXEC_BITS-1:0] alu_exec_payload, // alu_exec_t
    output logic mul_exec_valid,
    input logic mul_exec_ready,
    output logic [MUL_EXEC_BITS-1:0] mul_exec_payload, // mul_exec_t
    output logic mem_exec_valid,
    input logic mem_exec_ready,
    output logic [MEM_EXEC_BITS-1:0] mem_exec_payload // mem_exec_t
);
endmodule
```

### 13.11 `alu`

```systemverilog
module alu #(
    parameter integer PIPELINED = 1,
    parameter integer EARLY_RESOLVE = 0, BRANCH_ISOLATE = 0,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer CHECKPOINT_DEPTH = 4,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer CIDW = (CHECKPOINT_DEPTH > 1) ? $clog2(CHECKPOINT_DEPTH) : 1,
    parameter integer TAG_BITS = RW,
    parameter integer ALU_EXEC_BITS = TAG_BITS + CIDW + 6 + PW + 128,
    parameter integer RESULT_BITS = TAG_BITS + PW + 32,
    parameter integer RESOLVE_BITS = TAG_BITS + CIDW + 98
) (
    input logic clock, reset,
    input logic squash_valid,
    input logic [TAG_BITS-1:0] squash_tag,
    input logic [RW-1:0] rob_head,
    input logic exec_valid,
    input wire resolve_exec_valid,
    input wire [31:0] branch_operand1, branch_operand2,
    output logic exec_ready,
    input logic [ALU_EXEC_BITS-1:0] exec_payload,
    output logic result_valid,
    input logic result_ready,
    output logic [RESULT_BITS-1:0] result_payload,
    output logic resolve_valid,
    output logic [RESOLVE_BITS-1:0] resolve_payload
);
```

### 13.14 `lsu`

```systemverilog
module lsu #(
    parameter integer PIPELINED = 1,
    parameter integer RESULT_PIPELINED = PIPELINED,
    parameter integer BUFFER_STORES = 0,
    parameter integer STORE_FORWARD = 0,
    parameter integer RESPONSE_FIRST = 0,
    parameter integer REGISTER_STORE_RESULT = 0, STORE_LOOKAHEAD = 0,
    parameter integer BYPASS_STORE_RESULTS = 0, SPEC_READ_PREVIEW = 0,
    parameter integer EARLY_STORE_COMMIT = 0,
    parameter integer EARLY_STORE = 0, EARLY_LOAD = 0, FORWARD_WIDTH=3,
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer LQ_DEPTH = 8,
    parameter integer SQ_DEPTH = 8,
    parameter integer LOAD_OUTSTANDING = 8,
    parameter integer GEN_WIDTH = 16,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1,
    parameter integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1,
    parameter integer MIDW = (LIDW > SIDW) ? LIDW : SIDW,
    parameter integer LQ_CW = $clog2(LQ_DEPTH + 1),
    parameter integer SQ_CW = $clog2(SQ_DEPTH + 1),
    parameter integer TAG_BITS = RW,
    parameter integer MEM_ALLOC_BITS = 1 + MIDW + TAG_BITS + PW,
    parameter integer MEM_EXEC_BITS = TAG_BITS + 3 + MIDW + 96,
    parameter integer RESULT_BITS = TAG_BITS + PW + 32,
    parameter integer LD_REQ_BITS = GEN_WIDTH + LIDW + 32,
    parameter integer LD_RSP_BITS = GEN_WIDTH + LIDW + 32,
    parameter integer WRITE_REQ_BITS = 68
) (
    input logic clock, reset, squash_valid,
    input logic [TAG_BITS-1:0] squash_tag,
    input logic [RW-1:0] rob_head,
    input logic [GEN_WIDTH-1:0] current_gen,
    input logic [DISPATCH_WIDTH-1:0] disp_valid,
    input logic [DISPATCH_WIDTH*MEM_ALLOC_BITS-1:0] disp_lsq,
    output logic [LQ_CW-1:0] lq_free,
    output logic [SQ_CW-1:0] sq_free,
    output logic [DISPATCH_WIDTH*LIDW-1:0] lq_alloc_id,
    output logic [DISPATCH_WIDTH*SIDW-1:0] sq_alloc_id,
    input wire store_data_valid,
    input wire [PW-1:0] store_psrc,
    input wire [FORWARD_WIDTH-1:0] forward_valid,
    input wire [FORWARD_WIDTH*PW-1:0] forward_pdst,
    input wire [FORWARD_WIDTH*32-1:0] forward_value,
    input logic exec_valid,
    input wire read_exec_valid,
    output logic exec_ready,
    input logic [MEM_EXEC_BITS-1:0] exec_payload,
    output wire early_load_valid,
    output wire [PW-1:0] early_load_pdst,
    output logic result_valid,
    input logic result_ready,
    output logic [RESULT_BITS-1:0] result_payload,
    input logic st_start_valid,
    input logic [SIDW-1:0] st_start_id,
    output logic st_done_valid,
    output logic ld_req_valid,
    input logic ld_req_ready,
    output logic [LD_REQ_BITS-1:0] ld_req_payload,
    input logic ld_rsp_valid,
    input logic [LD_RSP_BITS-1:0] ld_rsp_payload,
    output logic st_req_valid,
    input logic st_req_ready,
    output logic [WRITE_REQ_BITS-1:0] st_req_payload,
    input logic st_rsp_valid
);
```

### 13.15 `axi_bridge`

```systemverilog
module axi_bridge #(
    parameter integer LQ_DEPTH = 8,
    parameter integer FETCH_QUEUE_DEPTH = 16,
    parameter integer AXI_RD_OUTSTANDING = 16,
    parameter integer AXI_WR_OUTSTANDING = 16,
    parameter integer GEN_WIDTH = 16,
    parameter integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1,
    parameter integer FIDW = (FETCH_QUEUE_DEPTH > 1) ? $clog2(FETCH_QUEUE_DEPTH) : 1,
    parameter integer IF_ID_WIDTH = FIDW,
    parameter integer IF_REQ_BITS = GEN_WIDTH + IF_ID_WIDTH + 32,
    parameter integer IF_RSP_BITS = GEN_WIDTH + IF_ID_WIDTH + 32,
    parameter integer LD_REQ_BITS = GEN_WIDTH + LIDW + 32,
    parameter integer LD_RSP_BITS = GEN_WIDTH + LIDW + 32,
    parameter integer WRITE_REQ_BITS = 68
) (
    input logic clock, reset,
    input logic if_req_valid,
    output logic if_req_ready,
    input logic [IF_REQ_BITS-1:0] if_req_payload,
    output logic if_rsp_valid,
    output logic [IF_RSP_BITS-1:0] if_rsp_payload,
    input logic ld_req_valid,
    output logic ld_req_ready,
    input logic [LD_REQ_BITS-1:0] ld_req_payload,
    output logic ld_rsp_valid,
    output logic [LD_RSP_BITS-1:0] ld_rsp_payload,
    input logic st_req_valid,
    output logic st_req_ready,
    input logic [WRITE_REQ_BITS-1:0] st_req_payload,
    output logic st_rsp_valid,
    output logic [31:0] araddr,
    output logic arvalid,
    input logic arready,
    input logic [31:0] rdata,
    input logic [1:0] rresp,
    input logic rvalid,
    output logic rready,
    output logic [31:0] awaddr,
    output logic awvalid,
    input logic awready,
    output logic [31:0] wdata,
    output logic [3:0] wstrb,
    output logic wvalid,
    input logic wready,
    input logic [1:0] bresp,
    input logic bvalid,
    output logic bready
);
endmodule
```

### 13.16 `icache`

```systemverilog
module icache #(
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer FETCH_QUEUE_DEPTH = 16,
    parameter integer ICACHE_SIZE_BYTES = 4096,
    parameter integer ICACHE_WAYS = 2,
    parameter integer ICACHE_LINE_BYTES = 32,
    parameter integer GEN_WIDTH = 16,
    parameter integer FIDW = (FETCH_QUEUE_DEPTH > 1) ? $clog2(FETCH_QUEUE_DEPTH) : 1,
    parameter integer DCW = $clog2(DISPATCH_WIDTH + 1),
    parameter integer IF_ID_WIDTH = $clog2(ICACHE_LINE_BYTES/4),
    parameter integer IC_REQ_BITS = GEN_WIDTH + FIDW + DCW + 32,
    parameter integer IC_RSP_BITS = GEN_WIDTH + FIDW + DCW + 32*DISPATCH_WIDTH,
    parameter integer IF_REQ_BITS = GEN_WIDTH + IF_ID_WIDTH + 32,
    parameter integer IF_RSP_BITS = GEN_WIDTH + IF_ID_WIDTH + 32
) (
    input logic clock, reset,
    input logic fetch_redirect_valid,
    input logic ic_req_valid,
    output logic ic_req_ready,
    input logic [IC_REQ_BITS-1:0] ic_req_payload,
    output logic ic_rsp_valid,
    output logic [IC_RSP_BITS-1:0] ic_rsp_payload,
    output logic if_req_valid,
    input logic if_req_ready,
    output logic [IF_REQ_BITS-1:0] if_req_payload,
    input logic if_rsp_valid,
    input logic [IF_RSP_BITS-1:0] if_rsp_payload
);
endmodule
```

### 13.17 `branch_predictor`

```systemverilog
module branch_predictor #(
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer ISSUE_WIDTH = 2,
    parameter integer BP_ENABLE = 1,
    parameter integer HISTORY_BITS = 0,
    parameter integer GLOBAL_HISTORY = 0,
    parameter integer BTB_RAM = 0,
    parameter integer BTB_ENTRIES = 64,
    parameter integer BHT_ENTRIES = 256,
    parameter integer BP_TRAIN_BITS = 66
) (
    input logic clock, reset,
    input logic [31:0] lookup_pc,
    output wire [DISPATCH_WIDTH-1:0] pred_taken,
    output wire [DISPATCH_WIDTH*32-1:0] pred_npc,
    // Events are packed in increasing ROB age by branch_ctrl.
    input logic [ISSUE_WIDTH-1:0] train_valid,
    input logic [ISSUE_WIDTH*BP_TRAIN_BITS-1:0] train_payload
);
```

## 14. 顶层连接

- Fetch.lookup_pc 接 branch_predictor.lookup_pc；预测器 pred_taken/pred_npc 返回 Fetch。branch_ctrl.train_valid/train_payload 接预测器，按 ROB 年龄压紧排序。BP_ENABLE/BTB_ENTRIES/BHT_ENTRIES 从 student_top 传入预测器。
- Fetch→Decode→Rename 的包接口不携带 generation；Fetch 在入口按 `{gen,id}` 过滤取指响应，任何重定向都清除尚未派遣的旧前端数据。branch_ctrl.fetch_redirect_* 接 Fetch，valid 同时接 ICache；current_gen 由 branch_ctrl 维护并用于产生重定向目标。
- Rename 的 disp_rob 接 ROB，disp_alu/disp_mem 分别接 IQ，disp_lsq 接 LSU。顶层按 disp_rob.kind 和统一 fire 产生 IQ/LSU 的有效 lane，squash 当拍禁止 fire；不要用前端纠正信号反向门控 fire。
- branch_ctrl 的 checkpoint 候选接 Rename；Rename 的 cp_alloc_* 和 front_redirect_valid/front_redirect_pc 返回控制器。cp_release_mask/restore_cp_id 只接 Rename；ROB、IQ、issue_sched、FU、LSU 和 wb_arb 接 squash_valid/tag，Rename 只接 squash_valid。
- rob_head 接两 IQ、issue_sched、各 FU、LSU、branch_ctrl、wb_arb，作为年龄比较基准；ROB 尾索引和容量返回 Rename。IQ 内部槽号不传出。
- issue_sched 的 ALU/MUL/MEM 执行投影分别接对应入口；每个入口保留完整身份用于局部取消。PRF 读口及窄 wake_* 连接保持。
- 每个 ALU.resolve_* 接 branch_ctrl 的对应 lane，不经过 wb_arb。三个执行源类别的 result_t 接 wb_arb；顶层先仲裁，再按 squash 年龄边界过滤 done/write。
- wb_arb.done_tag/valid 只接 ROB；write_* 只控制 PRF 写入。各 FU 的 result_valid/pdst 接 Rename 和两 IQ 的 wake_*，同时接 PRF 的 forward_*；控制流 npc 不进入完成转发。
- ROB.reg_commit_* 只接 Rename（仅携带 old_pdst）；st_start_* 接 LSU，st_done_valid 返回 ROB。LSU/DCache/桥的写请求和完成无 generation/ID，不受年轻分支恢复取消。
- Fetch→ICache 使用带 count 的包请求/响应；ICache→桥的 IF 与 DCache→桥的 LD 请求和响应都传递 `{gen,id}`；桥保留并原样返回，客户端按 `{gen,id}` 匹配身份。旧事务与新事务可以同时在桥中存在；generation 只由 branch_ctrl 在每次实际重定向时自增。branch_ctrl.current_gen 直连 LSU；Fetch 只从 fetch_redirect_payload.new_gen 更新本地 fetch_gen。
- 原 run/kill/restore、bridge_idle 和退休 recover_* 连接移除；也不再有 epoch 池相关端口。PRF 不接 squash，写入由 WB 筛选后的 write_valid 控制。外部 AXI 端口保持。

## 15. Instruction Cache 验证

`make test-icache` 运行 Cache/桥和 Fetch/Cache 定向测试，并以 SystemVerilog 2005 编译：覆盖宽度 1/2/4、相联度 1/2/4、行大小 16/32/64 B、单组 Cache、连续命中、填充/Load 竞争、背压、替换、跨行、槽号回绕、多次重定向以及命中/填充返回同拍重定向。还覆盖 IFETCH_OUTSTANDING 小于 D、输出阻塞、非 RAM PC 与 32 位 PC 回绕。

集成验证使用 `make test`、`make perf`、`make synth`。Docker 工具链中可加 `APPIMAGE=` 使用容器原生工具；这些测试不增加 RTL 验证或调试端口。

`python3 scripts/report.py` 使用本地 Docker 镜像（默认 `cpu2026:latest`，可用 `--image` 指定）依次运行 `make perf`、`make test`、`make synth`，在 `report/`（可用 `--output-dir` 指定）保存汇总报告。每份报告使用同目录下的 `<报告文件名去掉 .txt>.build/` 独立保存构建和综合产物；该目录挂载到容器 `/build`，显式设置 `BUILD=/build SYNTH_OUT=/build/synth`，避免复用其他用户拥有的仓库 `build/` 文件。容器使用调用者的 UID/GID，报告中记录宿主机构建目录，综合产物位于其 `synth/opt/` 子目录（配置 `MODE=diagnose` 时为 `synth/diagnose/`）。

## 16. 分支预测验证

`make test-branch` 用 SystemVerilog 2005 编译并运行 BTB/BHT 状态与冲突、ALU 分支元数据、checkpoint 训练过滤与年龄回绕、预测取指背压/截断/generation，WB 仲裁轮询/squash/指针回绕，以及宽度 1/2/4 的完整 CPU smoke 测试。`make test-icache` 保留顺序取指回归。完整功能及性能验证使用 `make test`、`make perf`，长程序可增大 MAX_CYCLES；代码变更必须通过 `make synth`。Docker 中使用 `APPIMAGE= VERILATOR=verilator` 运行测试；综合另指定 `YOSYS=yosys ABC=yosys-abc STA=sta ASAP7_LIB=/opt/asap7/lib`。

`make branch-accuracy APPIMAGE= VERILATOR=verilator` 编译带仿真统计器的 CPU，默认逐个运行全部 correctness/perf 测试，校验程序输出并记录分支预测正确率。可设置 `Case=perf_qsort` 选择单个程序、`BP_WIDTH=1|2|4` 设置 I/D/W/C、`BP_ENABLE=0|1` 对比顺序预测；统计测试的周期上限为 `BP_MAX_CYCLES`（默认 100000000）。`BP_STATS_OUT` 默认 `build/branch-accuracy`，生成 `accuracy.csv`（每个测试及加权汇总）、`by_pc.csv`（每个静态分支 PC）、`accuracy.json`（配置、源码 SHA-256、周期、分组与逐 PC 计数）及 `logs/*.stderr` 原始日志。Python 入口为 `tb/branch_accuracy.py`，支持重复 `--case` 和 `--kind all|correctness|perf`。无事件的正确率为 N/A/JSON null，失败或不完整测试不计入汇总，脚本返回非零。

统计口径为执行解析时 **预测 npc 与实际 npc 相等**，包含 BTB miss 的顺序预测，按条件分支/无条件跳转及实际 taken/not-taken 分组；跳转目标等于 PC+4 时也按 npc 比较，不推断方向正确率。计数只接受 `branch_ctrl.surviving` 的解析事件：checkpoint 身份匹配，且不年轻于本拍最老误预测分支。曾在更早周期解析、以后才被更老分支冲刷的事件保留，与执行期训练口径一致；这不是退休分支统计。无条件跳转组包含 JAL 和 JALR。汇总正确率为总正确次数/总预测次数，不平均各程序百分比。

`tb/branch_stats_bind.sv` 仅在专用仿真构建时将 `tb/branch_stats_monitor.sv` 绑定到 branch_ctrl，通过内部 cp_pred_npc 和 resolve_payload 观测，不修改 CPU 的综合接口、不进入 `verilog/filelist.f`。`make test-branch-accuracy` 验证统计解析/CSV/JSON、零事件、加权汇总、复位、多 lane 同 PC、taken 到 PC+4、目标变化、checkpoint 复用、stale 解析、squash 与 ROB 回绕，并用完整 CPU 运行 8 次条件分支的已知循环，检查开启预测器时正确 6 次、关闭时正确 1 次，以及 JAL/JALR 冷启动目标。


## 17. 300 MHz 时序优化与验证

默认 student_top 使用本文件第 2 节的紧凑配置，降低队列、寄存器及预测表的读写扇出；各容量仍可参数化扩大，但更大配置需独立综合和测量 IPC。外部 AXI 及各包的字段定义保持，模块默认参数与顶层传入参数应分别理解。

Fetch 对空闲尾部槽提前准备 PC、预测 npc、taken 和 generation，只有正常创建事件才发布槽 state。计数覆盖的在用槽不会被提前写覆盖；redirect/reset 只清状态。队列读写逐槽译码。ICache tag 在每组内比较后合并 hit，BTB/BHT 也在条目内译码，避免数组二进制读选择让地址位驱动每个数据位；缓存命中、填充及预测接口的延迟保持。

`make test-timing` 以 SystemVerilog 2005 运行写回流水级、checkpoint 预准备、多 lane 候选寄存器、年龄选择树、PRF 和乘除法定向回归，覆盖背压、同包多分支镜像、年轻目的回收、暂存结果冲刷、ROB 回绕、连续写回与复位。完整回归还需运行 `make test MAX_CYCLES=100000000`、`make perf`、`make test-branch`、`make test-icache`。

综合使用既有 Yosys/ASAP7/OpenSTA 流程，不改变时序约束、库或统计口径。300 MHz 目标可显式设置 `make synth CLOCK_PERIOD_NS=3.333`；验收需同时检查 `estimated_fmax_mhz >= 300` 及目标 setup slack 非负，不能仅凭 make 返回码认定满足频率。该频率为无布线寄生的综合估计。

历史紧凑配置（提交 f3ed8dd，D=I=W=C=1、K=1）实测：`make synth CLOCK_PERIOD_NS=3.333` 的 estimated_fmax_mhz 为 331.42 MHz，minimum_period_ns 为 3.0173 ns，worst_setup_slack_ns 为 +0.3161 ns，总面积为 6569.85 μm²。优化前同一工具链的频率约 131.34 MHz、面积 13115.85 μm²；容量变化与额外 WB/唤醒延迟使六项性能测试 IPC 几何平均从 0.2503 降至 0.2166。

历史提交 ccb3088 默认 D=I=W=C=2、K=4、BTB=64、BHT=256：双宽派遣与 Rename 输入重叠减少前端空拍，双宽发射/写回/提交增加后端吞吐，四个 checkpoint 允许多个未解析分支并行在途，扩大预测表减少索引冲突。每项调整单独提交，由 post-commit 的 `scripts/report.py` 测量全部性能、正确性和综合结果；当前配置的 IPC 与频率以对应提交的 `report/` 报告为准。

提交 ccb3088 的六项性能测试 IPC 几何平均为 0.3039，相比起点 82187b7 的 0.2166 提高 40.29%，每项 IPC 均提升；19 项 correctness 全部通过。当时使用现已撤销的映射设置，`make synth CLOCK_PERIOD_NS=3.333` 记录 estimated_fmax_mhz=411.98、minimum_period_ns=2.4273、worst_setup_slack_ns=+0.9057，总面积为 12304.86 μm²；结果保存在 `build/ipc-validation/synth-300/opt/`。定向回归 `make test-timing`、`make test-branch`、`make test-icache` 全部通过，包含 SV2005 连续派遣/跨包 RAW/部分派遣及恢复测试。这些数值是既有库与无布线寄生模型下的综合估计。

## 18. IPC 优化工作与 Data Cache 接口

当前工作配置为 D=I=W=C=1、R=32、P=64、LQ=SQ=8、F=16，DCache 默认 16 KiB/2 路/64 B 行。调度器、LSU 结果及请求缓冲支持消费与补入同拍；单发射 LSU 在空缓冲时直接发送请求/完成。Rename/ROB/IQ 的空闲槽提前准备载荷，仅有效位发布派遣，不覆盖仍被使用的槽或背压 offer。

DCache 为 WAYS 路组相联、write-back/write-allocate，顶层 DCACHE_WAYS 传给模块 WAYS，二者默认均为 2，支持 1/2/4。每路独立设置 tag SRAM 及按行内字分 bank 的单端口同步数据 SRAM；每个 SRAM 的 DEPTH=SIZE_BYTES/(WAYS×LINE_BYTES)，tag WIDTH=32-log2(LINE_BYTES)-log2(组数)。valid/dirty 使用逐路寄存器，按 `way×组数+set` 展平，更新控制以 16 行为单位分发。接受 RAM 请求的边沿并行读取所有路的 tag 和整行数据，并锁存地址、Store 数据/strobe 或 Load 的 {gen,LQ id}。下一周期 PROBE 比较所有路的 valid/tag 并选择命中路，Load 命中当周期回复；该 Load 命中周期可同时接受下一条请求，连续跨路 Load 命中仍为一条/拍。Store 命中在 PROBE 周期拉高 st_rsp_valid，接收完成事件的上升沿按 byte strobe 仅更新命中路的对应字 bank，期间背压下一条请求；完成事件不额外寄存一拍。miss 的 PROBE 周期背压，不会接受或覆盖下一条请求；victim 的路号、tag/数据从该次同步读锁存。MMIO 排空选择覆盖所有路的脏行，同步读取选定路/组的 tag/数据，再进入写回。

每组替换先选最低编号无效路；所有路有效时使用该组的轮转指针。INSTALL 边沿将指针设为本次安装路的下一路，到 WAYS-1 后回绕为 0；命中不改变指针。victim_way 在 miss 开始时锁存，整次脏写回、填充及安装都使用同一路号，其他路的数据及元数据保持。

一次 miss 占用控制器；脏 victim 逐字写回并等待全部 B，再从请求字开始环绕填充整行。Load 关键字返回时立即以原始 {gen,LQ id} 回复 LSU，其余字继续填充。INSTALL 边沿写入 tag SRAM 并设置 valid/dirty；Store miss 同边沿写入对应字。恢复不取消物理填充，不丢失已提交脏数据。复位清 valid/dirty/control，不清数据/tag SRAM。非 RAM Store 先排空全部脏行，再发送原始 MMIO 写，等待自身 B 完成。DCache 外部端口与载荷位布局不变。

CPU ld_req/ld_rsp 为 GEN_WIDTH+LIDW+32 位；Cache 到桥的 mem_ld_req/mem_ld_rsp 为 GEN_WIDTH+WORD_W+32，id 表示行内字号。请求保持到 ready，响应无 ready、每笔只发一次。Cache 的 st_rsp 表示 RAM 更新或 MMIO 完成；桥的 mem_st_rsp 始终表示真实 B 握手。

`make test-timing` 包含 tb/dcache.sv，以 SV2005 覆盖 1/2/4 路、16/32/64 B 行、单组、跨控制分组及默认 16 KiB 容量；检查关键字提前返回、连续跨路命中、跨命中/miss 的持续请求及返回身份、空路优先、同组冲突行共存、轮转脏替换、byte 合并、复位、MMIO 排空全部路的脏数据，以及深度 3 写队列的 AW/W 独立背压和回绕。还包含 LSU generation/Store 消歧测试：恢复边沿已接受的 RAM 读保持旧身份返回，清除的槽只归还额度；复用槽以新 generation 接收新响应。

2026-10-02 上轮开发记录：组合候选/写回、PRF 写入旁路版本六项 make perf 的 IPC 几何平均为 0.6259，19 项 make test 全通过。随后按字分 bank、恢复边沿读请求身份过滤和队列排名分配版本的 IPC 为 0.6202。按字分 bank 版本 estimated_fmax_mhz=80.55、minimum_period_ns=12.4149、worst_setup_slack_ns=-9.0813（3.333 ns 目标），尚未达标。上轮暂停时，完成结果直接转发阶段的六项 IPC 为 0.6208，19 项 correctness 全通过；控制分发 RTL 的 3.333 ns 综合估计为 114.11 MHz，minimum_period_ns=8.7638、worst_setup_slack_ns=-5.4307，总面积 30221.24 μm²，报告输入 SHA-256 与当时源码一致。该结果未达到 300 MHz，不能以性能结果或 make synth 返回码宣称目标已完成。历史 ccb3088 的 411.98 MHz 使用了之后被撤销的映射设置，不证明当前频率达标；验收保持原 scripts/synth.py、ASAP7/OpenSTA 约束和全六项性能统计。本轮结果见第 18.3 节。

### 18.1 `dcache`

```systemverilog
module dcache #(
    parameter integer SIZE_BYTES = 4096,
    parameter integer BULK_REFILL = 0, REFILL_HITS = 0,
    parameter integer HIT_UNDER_MISS = 0,
    parameter integer STORE_PIPELINE = 0,
    parameter integer WAYS = 2,
    parameter integer LINE_BYTES = 32,
    parameter integer LQ_DEPTH = 4,
    parameter integer GEN_WIDTH = 16,
    parameter integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1,
    parameter integer WORDS = LINE_BYTES / 4,
    parameter integer WORD_W = (WORDS > 1) ? $clog2(WORDS) : 1,
    parameter integer LD_BITS = GEN_WIDTH + LIDW + 32,
    parameter integer MEM_LD_BITS = GEN_WIDTH + WORD_W + 32
) (
    input wire clock, reset,
    input wire ld_req_valid,
    output wire ld_req_ready,
    input wire [LD_BITS-1:0] ld_req_payload,
    output wire ld_rsp_valid,
    output wire [LD_BITS-1:0] ld_rsp_payload,
    input wire st_req_valid,
    output wire st_req_ready,
    input wire [67:0] st_req_payload,
    output wire st_rsp_valid,
    output wire mem_ld_req_valid,
    input wire mem_ld_req_ready,
    output wire [MEM_LD_BITS-1:0] mem_ld_req_payload,
    input wire mem_ld_rsp_valid,
    input wire [MEM_LD_BITS-1:0] mem_ld_rsp_payload,
    output wire mem_st_req_valid,
    input wire mem_st_req_ready,
    output wire [67:0] mem_st_req_payload,
    input wire mem_st_rsp_valid,
    output wire line_req_valid, input wire line_req_ready,
    input wire line_rsp_valid,
    input wire [LINE_BYTES*8-1:0] line_rsp_data
);
```

### 18.2 控制信号分发与完成结果转发

signal_fanout 使用分支数最多为 4 的树，每条支路由两个反相器组成。keep_hierarchy/keep 保留缓冲边界，使标准单元映射后仍有真实的分发级；无状态、无协议延迟。ROB head 与恢复广播分别向各后端消费者分发；发射队列和调度器的选择及载荷使能按最多 16 位一组分发，PRF 的 bank 选择、写入数据和逐字写使能也分组分发。所有缓冲均参与原综合脚本的面积和 OpenSTA 时序统计。

Fetch 的 create_count 使用 CNT(D) 位，credits_used 使用 CNT(IFETCH_OUTSTANDING+D) 位；合法响应只归还已接受的当前 generation 指令额度。容量和行尾限制使用与常数边界的比较，不生成 32 位额度减法。队列及 outstanding 的更新按各自计数位宽运算，外部 count 和载荷位布局不变。输出包载荷不对无效 lane 清零，以 count 指定有效前缀；输出锁存使能通过 signal_fanout 按最多 16 位一组分发，阻塞期间仍保持已发布包不变。

Fetch 将 RAM PC 条件与每 lane 的 pred_taken 合并后，经 signal_fanout 分别传给创建控制和每个槽的 NPC 字段；32 位 NPC 按两个 16 位组选择，slot_taken 共享该槽低位组的控制。该分发树只含组合缓冲，不改变预测、创建或槽发布的周期。

Fetch 与 branch_predictor 的连续 PC 和顺序下一 PC 使用 pc_increment：整数参数 WORDS（默认 1，语义支持 0..D），输入 pc[31:0]，输出 next_pc[31:0]，组合关系为 `(pc+4*WORDS) mod 2^32`。零增量在本核中直接接线，不保留空层级实例；非零增量的底部两位原样传递，小范围字偏移先计算低位和/进位，较高位使用并行前缀归约。keep_hierarchy/keep 保留有逻辑的小型递增器边界，全部计入原综合的面积和时序。无时钟、无状态、不增加查询或取指流水级。`make test-branch` 增加独立算术对照测试，覆盖 WORDS=0..4、完整低 13 位组合、各级进位边界、32 位回绕及随机地址；tb/pc_increment_equiv.sv 的 Yosys SAT 对照对全部 32 位地址证明同一关系。

Rename 的临时空闲表按译码 lane 提前选择非零目的寄存器，不依赖该 lane 的队列额度；遇到 fit 失败或前端修正后，后续 lane 不发布。实际 free_q/RAT 仍只在有效派遣握手时提交有效前缀，提前准备不会消耗后缀寄存器。used_alu/used_mem/used_lq/used_sq/used_cp 使用 CNT(D) 位，每包计数上界为 D。tb/rename_stream.sv 覆盖宽度 1/2/4 的零额度停顿、恢复单条额度、额度变化时保持已发布包，以及部分派遣后缀的寄存器编号与 RAW。

顶层从 I 路 ALU、MULDIV 和 LSU 的完成结果产生 I+2 路唤醒和操作数转发，独立于 W 路写回端口；I=1 时 ALU 与 LSU 在结果缓冲为空时使用当拍结果，其余使用已锁存结果。PRF 的 forward_valid/forward_pdst/forward_value 只覆盖组合读值，write_* 仍控制唯一真实写入；p0 始终为零，reset 时不转发。物理目的在活跃指令之间唯一，恢复边界后的年轻结果不会成为存活较老指令的源；恢复边沿取消年轻 FU/候选，之后物理寄存器才可重新分配。

调度器按年龄选择和准备数据，恢复只在执行有效位发布处过滤年轻项。cand_take 可以消费被取消的年轻候选，不能使其在恢复后再次执行。FILTER_AFTER_SELECT=1 时写回仲裁先选择原始有效源，再过滤 done_valid/write_valid；源 ready 和指针不依赖 squash，未选择的年轻结果由所属 FU 在恢复边沿取消。默认 FILTER_AFTER_SELECT=0 保留先过滤再仲裁的行为。

### 18.3 2026-10-02 频率与面积优化测量

该历史测量保持当时的默认配置及原综合流程，基线与本轮均使用 `CLOCK_PERIOD_NS=2.0`、相同 ASAP7 标准单元库、理想时钟和无布线寄生模型。基线为提交 18d8390，测量产物分别位于 `build/freq-area-baseline/synth/opt/` 和 `build/freq-area-control/synth/opt/`；本轮 report.json 的 21 个 RTL 输入 SHA-256 均与本轮源码一致。`make synth` 成功只表示综合与分析流程通过。

| 指标 | 基线 | 本轮 | 变化 |
| --- | ---: | ---: | ---: |
| estimated_fmax_mhz | 119.3473 | 147.1687 | +23.31% |
| minimum_period_ns | 8.3789 | 6.7949 | -18.90% |
| area_um2（含 SRAM） | 30268.2159 | 24285.6640 | -19.77% |
| worst_setup_slack_ns（2.0 ns 目标） | -6.3789 | -4.7942 | +1.5847 ns |
| 六项 IPC 几何平均 | 0.6208 | 0.6117 | -1.47% |

同步 tag SRAM 减少寄存器和宽 tag 选择逻辑；Load 命中延迟和连续吞吐保持，干净 miss 需先经历 PROBE，多一拍 tag 查询。Store 命中在 PROBE 的 SRAM 写边沿完成，并背压下一请求；性能变化以上述完整六项测试为准。Fetch 的窄位宽计数、局部输出使能、预测控制分发和并行 PC 递增，以及 Rename 的空闲表提前准备，改善控制路径。全部改动使用 SystemVerilog 2005，综合约束及库未调整。147.1687 MHz 为综合估计，仍未达到 README-EN 的 300 MHz 门槛。

本轮验证：`make synth`、六项 `make perf`、19 项 `make test MAX_CYCLES=100000000`（19 passed / 0 failed）、`make test-timing`、`make test-branch`、`make test-icache` 全部通过，完整软件回归容器退出码为 0。pc_increment 的 WORDS=0..4 全地址 SAT 等价证明通过。Docker 测试和综合逐项串行执行，编译 JOBS=2，测试容器限内存 4 GiB、综合容器限 5 GiB。软件回归日志为 `build/freq-area-control/software-validation.log`，定向回归日志为 `build/freq-area-control/directed-validation.log`，前后测量及输入哈希对照为 `build/freq-area-control/comparison.json`。SAT 可在同一 Docker 工具环境用 `yosys -p 'read_verilog -sv verilog/pc_increment.sv tb/pc_increment_equiv.sv; prep -top pc_increment_equiv -flatten; sat -verify -prove matched 1 -set-def-inputs'` 复现。

### 18.4 2026-10-08 单发射 IPC 优化

默认顶层改为 I=D=W=C=1；队列、Cache 和预测表容量保持第 2 节配置。比较基线也使用 I=D=W=C=1，仅保留优化前流水行为，避免将宽度切换算入 IPC 收益。未修改性能程序、指令计数或内存延迟。

优化包括 D=1 连续 Rename 派遣、ALU 结果直通及背压缓冲、Fetch 当前响应旁路、LSU AGU 请求准备及匹配响应旁路。全核总发射仍每拍最多一条，写回及提交仍每拍最多一条；分支解析保留寄存器边界。

| 程序 | 单发射基线周期 | 优化后周期 | 基线 IPC | 优化后 IPC | IPC 提升 |
| --- | ---: | ---: | ---: | ---: | ---: |
| perf_median | 21514 | 15109 | 0.3236 | 0.4607 | +42.39% |
| perf_multiply | 49415 | 27715 | 0.4396 | 0.7838 | +78.30% |
| perf_qsort | 386678 | 252398 | 0.3618 | 0.5543 | +53.20% |
| perf_rsort | 414722 | 316564 | 0.4719 | 0.6183 | +31.01% |
| perf_towers | 12474 | 9641 | 0.4231 | 0.5475 | +29.38% |
| perf_vvadd | 10591 | 8491 | 0.4272 | 0.5328 | +24.73% |
| 几何平均 | — | — | 0.4046 | 0.5749 | +42.07% |

分阶段 IPC 几何平均：基线 0.4046，连续 Rename 0.5409，加入 LSU 旁路 0.5545，再加入 Fetch/ALU 旁路 0.5749。

复现命令：`make perf APPIMAGE= BUILD=build/ipc-single-optimized MAX_CYCLES=100000000 JOBS=4`，LATENCY=10，Verilator 5.032，以 SystemVerilog 2005 编译。六项性能程序输出校验全部通过；对比、各阶段周期及最终源码 SHA-256 保存在 `build/ipc-single-comparison.json`，原始日志为 `build/ipc-single-{baseline,rename,lsu,optimized}.log`。

另外仅运行改动相关定向测试：Rename 连续派遣/跨包 RAW/宽度 1、2、4/背压/单路 checkpoint 恢复；ALU 直通/背压替换/ROB 回绕/分支单次解析；Fetch generation、预测路径及 ICache 连续取指；LSU generation、旧 Store 消歧、响应扩展/背压/恢复。均通过。按本轮要求未运行综合，也未重跑完整 correctness 程序集；这些 IPC 结果不代表新配置的频率或面积。

### 18.5 2026-10-08 DCache 路数参数化

顶层增加 DCACHE_WAYS=2，传入 dcache.WAYS；支持 1/2/4 路。总数据容量为 16 KiB，默认每路 256 组、32 B 行；逐路 tag/数据 SRAM，空路优先及按组轮转替换，MMIO 排空全部路的脏行。Load 命中延迟与每拍一条的连续吞吐保持。接口及参数定义见第 2、13.1、18.1 节。

| 性能程序 | 直接映射 IPC | 两路 IPC | IPC 变化 |
| --- | ---: | ---: | ---: |
| perf_median | 0.4607 | 0.4607 | +0.00% |
| perf_multiply | 0.7838 | 0.7838 | +0.00% |
| perf_qsort | 0.5543 | 0.5573 | +0.55% |
| perf_rsort | 0.6183 | 0.6641 | +7.41% |
| perf_towers | 0.5475 | 0.5475 | +0.00% |
| perf_vvadd | 0.5328 | 0.5328 | +0.00% |
| 几何平均 | 0.5749 | 0.5823 | +1.29% |

六项性能程序输出校验全部通过。tb/dcache.sv 的 16 组配置全部通过，覆盖路数 1/2/4、16/32/64 B 行、单组、默认 16 KiB、冲突行共存、轮转脏替换、连续跨路命中、byte 合并、复位、MMIO 全路排空及 AXI 背压。

复现 IPC：`make perf APPIMAGE= BUILD=build/ipc-dcache-two-way MAX_CYCLES=100000000 JOBS=4`。使用 Verilator 5.032、SystemVerilog 2005、LATENCY=10；直接映射基线复用上一轮优化后的仿真器，两次测量的其余 CPU 参数、程序与内存延迟相同。对比、周期及源码 SHA-256 保存在 `build/ipc-dcache-two-way/comparison.json`，定向日志为同目录 `directed-tests.log`。本轮按先前要求未运行综合。

### 18.6 2026-10-08 单发射 IPC 超过 0.65

目标按六项 perf_* 的 IPC 几何平均衡量。最终默认仍为 I=D=W=C=1、K=4、DCache 总容量 16 KiB/2 路，行大小改为 64 B，每路 128 组。性能程序、动态指令计数、LATENCY=10 和其余 CPU 参数保持不变。

主要修改：Store AGU 同拍参与完成选择，ROB 接收队头 Store 的 WB 完成时即可授权，LSU 当拍发出授权写；单发射 LSU 空请求缓冲直通 Load 请求，空结果缓冲直通匹配响应，背压则保存并保持。Store 仍只在 ROB 头部授权，Load 仍等待未知或重叠的旧 Store，generation 和 squash 规则保持第 10 节定义。增大 Cache 行减少顺序数据访问的整行填充次数。

| 性能程序 | 本轮基线周期 | 最终周期 | 基线 IPC | 最终 IPC | IPC 提升 |
| --- | ---: | ---: | ---: | ---: | ---: |
| perf_median | 15109 | 13282 | 0.4607 | 0.5241 | +13.76% |
| perf_multiply | 27715 | 27314 | 0.7838 | 0.7953 | +1.47% |
| perf_qsort | 251015 | 230134 | 0.5573 | 0.6079 | +9.07% |
| perf_rsort | 294719 | 255547 | 0.6641 | 0.7659 | +15.33% |
| perf_towers | 9641 | 8034 | 0.5475 | 0.6570 | +20.00% |
| perf_vvadd | 8491 | 7326 | 0.5328 | 0.6175 | +15.90% |
| 几何平均 | — | — | 0.5823 | **0.6547** | **+12.43%** |

分阶段几何平均：本轮基线 0.5823，缩短 Store 路径 0.6078，LSU 结果直通 0.6205，64 B 行 0.6446，Load 请求直通 0.6547。最终默认配置重新编译测量，六项输出全部正确。

新增 `tb/ipc_stats.sv` 和 `tb/ipc_profile.py`，只在仿真构建中绑定，统计取指空闲、候选缺失、派遣/提交、ROB/IQ/LSQ/checkpoint 阻塞、队头访存等待、Cache miss/背压、WB 冲突及逐 PC 分支错误。计数为周期条件统计，可能重叠；它们不改变原程序的 IPC 计数。复现命令：`python3 tb/ipc_profile.py --out build/ipc-065-final --appimage '' --jobs 4`；可用 `--case perf_qsort` 选择程序、`--parameter NAME=N` 对比顶层参数。周期、原始 stderr、分支统计及源码 SHA-256 在 `build/ipc-065-final/profile.json` 和各程序 `.stderr`，与本轮基线的对比在 `build/ipc-065-final/comparison.json`。

定向测试通过：LSU PIPELINED=0/1 的 generation、槽复用/旧响应过滤、请求/结果直通、byte/halfword 扩展、WB 背压、squash 和旧 Store 消歧；Store AGU/ROB/Cache 请求同拍、写回背压禁止授权、Cache 背压保持、恢复保留授权写、后继 Store 与 SQ/ROB 回收。DCache 的 16 组路数/行大小/容量配置也通过。均使用 SystemVerilog 2005。按用户要求未运行综合；本节只报告 IPC，不报告新配置的频率或面积。

## 19. 单发射十级流水（2026-10-09）

本节记录本轮优化前 I=D=W=C=1 的十级流水基线；当前默认与时序以第 20 节为准。主流水为 **F1 → F2 → ID → RN → DP → IS → RR → EX → WB → CM**；队列等待、Cache miss、乘除法迭代与 Store 授权等待不计入固定级数。默认缓存、队列与预测容量沿用第 2 节，Makefile 的默认目标时钟周期为 5 ns（200 MHz）。综合映射流程、库与 STA 约束预算不变。

| 级 | 组合工作 | 末端寄存边界 |
|---|---|---|
| F1 | PC/分支预测、额度与行尾限制、取指请求 | ICache 同步 SRAM 输出与请求元数据、Fetch 预测槽 |
| F2 | 命中/填充响应身份匹配与顺序组包 | Fetch 两项输出 FIFO |
| ID | RV32IM 译码与无效字段规范化 | decode_pipe 两项 FIFO |
| RN | RAT 读、平衡树选择空闲物理目的、记录旧目的 | single_rename 的单项派遣元数据、更新 speculative RAT/free/ready |
| DP | 查询资源，原子分配 ROB/IQ/LSQ/checkpoint | 各后端队列的有效项 |
| IS | 就绪候选按 ROB 年龄仲裁，总计最多一条/拍 | issue_select 两项 FIFO，保持物理源编号 |
| RR | PRF 读与完成结果旁路，按功能单元路由 | operand_read 各功能单元输入寄存器 |
| EX | ALU/分支或 AGU；M 扩展进入独立执行流水 | ALU result/resolve 寄存器、LSQ 地址状态 |
| WB | 仲裁已完成结果并更新 PRF/ROB | PRF 数据、ROB done 位 |
| CM | 按序退休，释放旧目的；队头 Store 授权/完成 | ROB head/count 与物理寄存器空闲位 |

### 19.1 前端与发射读数边界

`decode` 保持组合译码接口；新增 `decode_pipe` 包装层，参数为 DISPATCH_WIDTH/DCW/FETCH_BITS/DECODE_BITS，端口为 clock/reset/fetch_redirect_valid 以及原 fetch、decode 保持型通道。两项 FIFO 的 ready 仅取决于本地占用，reset/redirect 清有效状态，不清无效载荷。其源码与 decode 一同位于 verilog/decode.sv。

F1 空闲时直接提交预测取指请求。首次背压时冻结 PC/count/预测信息，预测器训练不能改变已发布请求；接受后推进 PC 并预留 Fetch 槽。F2 对队头匹配响应直接组包，前方缺失或输出满时保存到预留槽；输出两项 FIFO 不增加强制串行阶段。

issue_sched 的外部端口与位宽不变；内部拆为 issue_select 和 operand_read。两者的 `issue_valid/ready/payload` 是保持型通道。载荷为 `{rob:RW, cp_id:CIDW, op:6, pdst:PW, ps1:PW, ps2:PW, mem_id:MIDW, pc:32, imm:32}`，默认 98 位。IS 只使用本地两项 FIFO 的剩余容量，不跨 PRF 组合读；RR 只读取已锁存的物理源地址。正常状态支持每拍一项入/出；全满恢复允许一拍信用返回气泡。

每个 IS/RR 项与每个 RR/EX 输入寄存器都按周期开始时 ROB head 比较年龄。squash 取消年轻项并压紧队列，保留更老项；存活项可在恢复边沿正常转移。RR/EX 的 AGU offer 在恢复当拍仍可发布，由 LSU 按 tag 过滤后再更新 LSQ；RR/EX 的年轻有效位在恢复边沿清除，不会继续发布。每拍 IS 总接受数仍不超过 ISSUE_WIDTH，默认一条，新增缓冲不增加发射宽度。

### 19.2 连续单路重命名与派遣

rename 在 D=1 时实例化 single_rename；宽度大于一的既有实现保留。单路 RN 在 decode_valid&&decode_ready 边沿分配物理目的并更新 speculative RAT。下一拍 DP 原子分配后端队列。DP 消费与下一条 RN 接受可同拍发生，因此源映射自然包含前一条 RN 的更新，持续吞吐为一条/拍。

RN/DP 元数据（op/pc/npc/imm/ps1/ps2/pdst/old_pdst）在阻塞期间保持。ROB tag、LSQ id、checkpoint id 为 **DP 分配预览**，不在 RN 保留；相关 disp_* 投影仅在 disp_fire 时被下游采样。D=1 的 disp_valid 表示当前 DP 元数据具备全部分配容量，容量消失可撤销事件资格；它不是旧版承诺冻结所有槽编号的保持型通道。disp_ready 由顶层容量核查，disp_fire 仍统一控制所有分配。未派遣的 RN 目的已经保留于物理空闲表，但没有 ROB/IQ/LSQ/外部副作用。

分支的 RAT 快照在 RN 保存，包含该分支自身的目的映射；DP 分配 checkpoint 时发布此快照。checkpoint 的 younger_alloc 同时记录并行接受的下一条 RN 物理目的，也记录尚未 DP 的年轻 RN 项。误预测恢复回收所有这些目的并清 RN/DP offer，保留分支自身和更老映射；不依赖后端 generation。非控制流错误预测的前端修正在 DP 发出，禁止同拍接收旧路径的下一条 RN。

### 19.3 执行与验证范围

ALU 使用已寄存 EX/WB 结果，分支解析仍由寄存 resolve 发出；WB 不再另加流水寄存器。CM 仅依据周期开始时的 ROB done 位决定退休。LSU 保留当前单路请求/响应直通与队头 Store 提前授权；Store 仍仅在 ROB 头获得写权限，Load 仍遵守旧 Store 地址消歧与 generation 匹配。

LSU 的 Load 请求选择与 Load/Store 完成选择改为平衡年龄树；同年龄时保持原有低编号优先顺序。默认 8 项 LQ 加 8 项 SQ 的完成选择由逐项串联改为四层树。完成树先选出最老完成项，再按 squash 年龄限制是否留存；最老项若年轻，其余完成项也年轻。单路直通的年轻完成可在恢复当拍发布，由 WB 年龄过滤丢弃；IQ/PRF 的旁路只可能影响同时被取消的年轻依赖者。LSU 不在恢复边沿保存年轻结果，即使 WB 背压也不会使其后续重新出现。旧 generation 响应仍不成为候选。

AGU 的 RAM 地址分类按 LQ 项分发；ROB 的 Store 槽编号持续预览队头，只有 st_start_valid 授权才可消费。单路 branch_ctrl 的 squash_tag/restore_cp_id 提前投影已寄存 resolve 身份，仅 squash_valid 有效时消费；RN 的恢复 checkpoint 编号按物理寄存器分发，IS 队列的复制/入队捕获控制按 16 位分发。上述变化不增加协议延迟或改变正常完成、发射优先级。

DCache 的命中数据先在每路选择所需 32 位字，再按命中路选择，避免命中判断控制整行数据选择器。请求地址选择、按字 SRAM bank 控制与地址、替换行捕获使能通过 signal_fanout 分发；替换行捕获按 16 位分组。缓冲单元保留于标准单元映射并计入面积及 STA，无协议延迟。响应数据由 PROBE 状态选择命中数据，ld_rsp_valid 单独决定是否消费。

乘法拆为 16×16 部分积寄存、累加寄存、高半部符号校正/完成三个步骤；除法保留逐位迭代。乘除输入、内部计算和结果缓冲均按 ROB 年龄取消年轻工作。乘除与 Cache miss 是可变延迟支路，不改变主 ALU 路径的十级定义。

`make test-timing Case=pipeline_stages_test` 可选择单项；tb/run_timing.py 的 --case 可重复指定，只编译所选测试。Makefile、定向测试和 IPC 统计脚本默认 JOBS/--jobs=1，各测试顺序执行；本轮 Docker 运行内存上限为 3 GiB，综合与测试也顺序执行。新增 pipeline_stages_test 检查实际顶层 F2 返回到 CM 的逐拍边界与依赖 Store 退出；selection_tree_test 覆盖 IS/RR 背压、取消与保留、单/多路读取路由。定向测试与统计绑定不进入正式综合 filelist。

### 19.4 默认配置实测

SystemVerilog 2005、默认 I=D=W=C=1，六项原性能程序及动态指令计数不变，访存 LATENCY=10。最终 RTL 重新编译后，所有输出正确；以下周期数也与本轮时序优化前一致。

| 性能程序 | 周期 | IPC |
|---|---:|---:|
| perf_median | 14505 | 0.4799 |
| perf_multiply | 29022 | 0.7485 |
| perf_qsort | 269609 | 0.5189 |
| perf_rsort | 270348 | 0.7240 |
| perf_towers | 8218 | 0.6422 |
| perf_vvadd | 7692 | 0.5881 |
| 几何平均 | — | **0.6089** |

`make synth` 的 opt 模式、默认 5 ns 目标通过，仓库 ASAP7/估算 SRAM 模型的 STA 结果为：最低周期 **4.8291 ns**，估计最高频率 **207.0779 MHz**，5 ns 下最差 setup slack **+0.1713 ns**，总面积 **18610.505 μm²**。此频率为仓库综合时序估计，采用 ideal clock、无布线寄生的既有模型。输入/输出延迟各 0.2 ns、时钟 uncertainty 0.05 ns 等约束预算保持原值。

综合报告位于 `build/pipeline-single/v8/synth/opt/report.json`，性能统计位于 `build/pipeline-single/final/profile.json`；两者记录的 RTL SHA-256 与最终源码一致。容器内复现：`make synth APPIMAGE= SYNTH_OUT=build/pipeline-single/recheck-synth`，然后顺序运行 `python3 tb/ipc_profile.py --out build/pipeline-single/recheck-ipc --appimage '' --jobs 1`。IPC >0.6 指六项程序的几何平均，各单项数值如表。

最终定向验证通过：rename_stream_test（D=1/2/4）、selection_tree_test、dcache_test（16 组路数/行大小/容量配置）、lsu_generation 和 lsu_pipeline_test（各 PIPELINED=0/1）、store_pipeline_test、lsu_disambiguation（PIPELINED=0/1）、pipeline_stages_test。恢复当拍年轻响应与 WB 背压的组合也通过。另复用最终仿真器运行 correctness_expr，通过，937 周期。乘除 609 项及宽路 checkpoint 测试在此前通过，相应 RTL 随后未改动。本轮按请求仅选择必要项目，未运行完整正确性回归。

## 20. 阶段 2 单发射优化（2026-10-09）

本节覆盖第 19 节的默认配置和默认时序。当前 I=D=1、W=C=2，仍每拍最多发射一条；允许不同延迟功能单元的结果同拍写回，以及最多两条已完成指令按序退休。ROB 32、PRF 48、ALU/MEM IQ 各 4、LQ/SQ 各 8、checkpoint 4、BTB 32、BHT 256；I$ 1 KiB/2 路/32 B，D$ 16 KiB/2 路/64 B。默认目标周期改为 3.333 ns。面积和频率仍采用仓库原 ASAP7、FakeRAM 和 STA 模型。

### 20.1 取指、重命名和单发射

单路 Fetch 启用 `OUTPUT_BYPASS=1`，空输出 FIFO 可将匹配响应直接交给组合 decode。rename 新增 `DIRECT_RENAME=0`、`CHECKPOINT_RAM=0`；默认 I=D=1 时均设为 1，RAT 查询、物理目的选择与后端资源分配在同一派遣边沿完成，阻塞时不提前消耗目的或更新 RAT。宽路和独立模块的默认流水模式保留。

checkpoint 的整张 RAT 快照存入同步 FakeRAM（默认 4×192 bit），快照包含分支自己的目的映射；年轻分配掩码仍用寄存器。squash 边沿读快照并回收年轻目的，下一边沿恢复 RAT，期间暂停重命名一拍。非控制流错误预测的前端修正寄存后发布。

I=1 实例化 `single_issue`，候选年龄仲裁与 PRF 读在同一 RR 边沿锁存，不再经过 issue_select FIFO。三个 ALU/MUL/MEM RR 保持项保存物理源编号，执行时用真实完成值再次旁路；阻塞时保留已旁路的值。ALU 的确定执行和 Load 的确定结果入寄存器分别提前一拍唤醒 IQ，依赖者下拍 EX 使用真实寄存结果。提前唤醒不更新 Rename ready 或 PRF。恢复时允许准备候选数据，但只保存年龄存活项；被取消项不会随后重新发布。I>1 继续使用 issue_sched。

`single_issue` 新端口：`mem_cand_src2_ready` 表示 Store 候选数据就绪，`mem_store_psrc[PW]` 与 `mem_store_data_valid` 投影给 LSU；`early_wake_valid/early_wake_pdst[PW]` 为 ALU 预测唤醒；`branch_exec_valid` 为未经过 squash 反馈的实际 EX 资格。

ALU 共用加减/目标加法、比较和移位数据通路。新增参数 `EARLY_RESOLVE=0` 和输入 `resolve_exec_valid`；顶层设 EARLY_RESOLVE=0，分支解析与结果均经过 EX 末端寄存器，再由 branch_ctrl 恢复，避免将写回背压、分支目标运算和 LSU 请求串入一条组合路径。分支解析资格独立于其产生的 squash，避免取消反馈环。

### 20.2 LSU 和退休

LSU 参数增加 `RESULT_PIPELINED=PIPELINED`、`BUFFER_STORES=0`、`EARLY_STORE=0`、`EARLY_LOAD=0`、`FORWARD_WIDTH=3`。默认顶层请求 PIPELINED=1，结果 RESULT_PIPELINED=1，BUFFER_STORES=1，单路 EARLY_STORE=EARLY_LOAD=1。Load 请求与结果均经寄存器，分别隔断 AGU/恢复到 Cache、内存响应到 IQ 的组合路径。

IQ 的 `EARLY_STORE` 模式允许 Store 基址就绪时先执行 AGU，`cand_src2_ready[I]` 表示真实数据就绪。LSU 新输入为 `store_data_valid`、`store_psrc[PW]`、`forward_valid[FORWARD_WIDTH]`、`forward_pdst[FORWARD_WIDTH*PW]`、`forward_value[FORWARD_WIDTH*32]`；SQ 保留未就绪物理数据源，真实完成到达后补齐数据。Store 地址和数据都就绪后才报告 ROB 完成。Load 仍等待未知地址或字节重叠的旧 Store，无 Store-to-Load 数据转发。

LSU 新输出 `early_load_valid/early_load_pdst[PW]` 只针对本拍确定选择并进入结果寄存器的 Load，用于下一拍依赖操作的真实结果旁路。未获得结果缓冲容量时不提前唤醒。

Store 在 ROB 头获得授权后进入 SQ_DEPTH 项已提交 FIFO。RAM Store 下一拍应答 ROB 以释放退休阻塞，SQ 槽直到 DCache 写完成才释放；已授权项按序排空并跨 squash 保留，消歧始终视其为较老 Store，不受 ROB 编号回绕影响。MMIO Store 仍等待真实写响应，不能提前触发退出。ROB 每拍最多授权一条 Store，已应答队头 Store 可与后继非 Store 同拍退休。

### 20.3 预测与预取

branch_predictor 新参数 `HISTORY_BITS=0`；顶层设为 4。保留 PC 索引的 bimodal BHT，增加 PC XOR 局部历史索引的 2-bit 计数表，以及每 BTB 项局部历史和 2-bit 选择器。条件分支解析后训练，选择器选择两种方向预测。训练控制每 8 个表项用 signal_fanout 分发，降低全表写使能负载。独立模块 HISTORY_BITS=0 的原 bimodal 行为保留。

新增 `data_prefetch`：三个下一行 SRAM 缓冲，需求读优先，预取只使用空闲读通道。扩展内部 Load ID 两位：0 表示需求，1..3 标识预取槽；generation 保持 16 位。槽内逐字有效位支持乱序返回；收到完整行后可一次性供 DCache 安装整行，减少逐字回填等待。写请求接受时使所有预取快照失效，在途旧预取继续排空后才能复用槽，避免返回过期内存内容。

DCache 新参数 `BULK_REFILL=0` 和端口 `line_req_valid/line_req_ready`、`line_rsp_valid/line_rsp_data[LINE_BYTES*8]`。请求地址由当前普通需求回填载荷给预取器，line 握手优先于逐字回填；同步 SRAM 下拍返回整行，再安装 tag。顶层 DATA_PREFETCH=1 时开启。`REFILL_HITS=0` 可选模式允许部分回填字命中，默认关闭以节省面积。整行选择和 SRAM 写控制按小组分发，缓冲单元计入综合面积与 STA。

### 20.4 验证入口

默认 `make test-timing JOBS=1` 仅串行运行六项定向测试：共享 ALU、single_issue、direct_rename、store_buffer、data_prefetch、dcache_stage2。`Case=...` 选择单项，`TIMING_ALL=1` 才运行完整定向回归。DCache 默认定向项仅测当前 16 KiB/2 路/64 B 配置，覆盖脏替换、MMIO、背压和部分回填；完整配置矩阵仍保留。所有源码采用 SystemVerilog 2005，测试和综合不同时运行。

性能使用原六项程序、原动态指令计数和 LATENCY=10，各程序顺序执行并校验输出。结果及源码 SHA-256：`build/stage2/v12/profile.json`。

| 程序 | 周期 | IPC |
|---|---:|---:|
| perf_median | 10371 | 0.6712 |
| perf_multiply | 25074 | 0.8663 |
| perf_qsort | 207013 | 0.6758 |
| perf_rsort | 221313 | 0.8844 |
| perf_towers | 7264 | 0.7266 |
| perf_vvadd | 6046 | 0.7483 |
| 几何平均 | — | **0.7575** |

## 21. Tier 2 单发射优化（200 MHz 目标）

本节覆盖第 17–20 节的历史配置。当前 I=D=1、W=C=2，每拍最多从 ALU/MUL 与 MEM 候选中选一条指令；多执行单元同时完成不增加发射宽度。仿真监视器检查每拍实际 cand_take 总数不超过 ISSUE_WIDTH。外部 AXI 端口和所有现有 packed 载荷位布局不变。

### 21.1 IQ、读数和分支恢复

`iq_core`、`iq_alu`、`iq_mem` 新增 `ORDERED_SELECT=0`。顶层单发射设为 1：入队时记录槽之间的先后关系，候选为没有更老就绪项的就绪槽。派遣 lane 必须按 ROB 年龄递增；槽复用重建该槽的关系，清除/取消项不参与选择。默认 0 保留年龄比较树。当前 ALU IQ 7 项、MEM IQ 4 项，LQ 4 项、SQ 8 项。

`single_issue` 新增 `EARLY_BRANCH=0`、`DELAYED_FORWARD=0`、`REGISTERED_LOAD_BRANCH=0`、`SNAPSHOT_LOAD_FORWARD=0`；顶层均开启。EX 分支解析使用独立的一次性事件，阻塞时不重复解析。顶层 ALU `EARLY_RESOLVE=1`、`BRANCH_ISOLATE=1`，分支恢复不等待 WB。`single_issue` 输出独立 `branch_operand1/branch_operand2[31:0]`，顶层旁路当前 ALU/MUL 完成与全部前一拍完成；ALU 的分支比较、JALR 加法使用该通路，普通结果加法保持原操作数通路，避免 SRAM 响应经共用加法器形成无功能意义的恢复长路径。单发射 PRF `BYPASS_WRITE=0`；RR 与完成同拍时，完成值在 EX 由前一拍完成副本补齐，当前拍真实完成具有更高优先级。ALU 预测唤醒仅使依赖者进入 RR，真实数据仍在 EX 取得。Load 使用实际完成唤醒（EARLY_LOAD=0）；RR 与当前 Load 完成同拍时保存 RAW 完成副本，EX 由前一拍完成值补齐。SNAPSHOT_LOAD_FORWARD 开启时，当前 LSU 完成不进入 EX 的所有 src1 和 ALU/MUL src2；MEM src2 仍允许当前完成旁路，满足提前执行地址而晚到数据的 Store。该模式要求 DELAYED_FORWARD=1、最后一个 forward lane 为 LSU、Load 使用实际完成唤醒。REGISTERED_LOAD_BRANCH 仅屏蔽当前 LSU 到分支的旁路，SNAPSHOT_LOAD_FORWARD 进一步覆盖地址和算术通路。实际发射仍每拍最多一条，不增加 Load 执行级数。

`prf` 新增 `WORD_RAM=0`，顶层开启。p1..P-1 分别存入连续读取的独立 32 位 SRAM，p0 固定为零。前一拍实际 WB 写入的值旁路覆盖写拍的 SRAM 读空隙；同时命中时最高 WB lane 优先。复位仍只将 p1..p31 清零，其他物理字保留。复位分发与写后读旁路不改变 PRF 原有写边沿或 BYPASS_WRITE 语义。

ALU/MEM 仲裁以 `(mem_tag<alu_tag) XOR (mem_tag<rob_head) XOR (alu_tag<rob_head)` 判定候选先后，等价于两个模 R 年龄相减再比较，避免在候选路径串联两组减法。该等价性已通过 R=32 的全输入 SAT 证明。

`wb_arb` 新增 `DEDICATED_ALU=0`。I=1、W≥2 且开启时 ALU 保证有完成通道，其他完成使用剩余通道，避免 ALU 可执行条件与其分支恢复形成组合反馈。顶层开启。

`rename` / `single_rename` 新增 `CHECKPOINT_BANKED=0`。与 CHECKPOINT_RAM 同时开启时，每个 checkpoint 使用独立 SRAM，连续读取，使 squash 边沿即可恢复 RAT。若所选 SRAM 刚写入，用当前 RAT 补齐写后读间隙；单路派遣下它恰好包含该分支自己的目的分配。默认 0 保留共享同步 SRAM 的延迟恢复。顶层单发射开启。

### 21.2 Store 转发与授权退休

LSU 新增 `STORE_FORWARD=0`、`RESPONSE_FIRST=0`、`EARLY_STORE_COMMIT=0`、`REGISTER_STORE_RESULT=0`、`STORE_LOOKAHEAD=0`，顶层均开启。RAM Load 等待所有未知地址旧 Store；地址已知时选择与所读字节重叠的最新旧 Store。只有它完整覆盖 Load、数据就绪且没有未知地址旧 Store 时转发，按 Load 类型扩展，不产生 Cache 请求、不占外部读额度。部分覆盖继续等待。已授权 Store 永远早于活跃 ROB 项，它们之间按提交 FIFO 顺序比较，不能用可复用的 ROB 编号比较。授权时记录 FIFO 槽 ticket，距 commit_head 的模 SQ_DEPTH 距离给出有效项的顺序，不再为每个 Load 搜索整个 FIFO；ticket 回绕保持同一顺序。

RESPONSE_FIRST 使当前匹配 Load 响应优先使用结果通道，其他完成保留在 LQ/SQ；恢复仍取消年轻结果。当前响应按每个 LQ 槽独立核验 `{gen,id}`、有效位与等待状态，one-hot 选择 ROB tag 和物理目的；响应优先时，已就绪队列的年龄选择树不包含当前响应，返回数据与身份直接覆盖队列结果。选择顺序和背压保持不变，减少响应身份经年龄树后再唤醒 IQ 的组合深度。当前顶层 LSU `PIPELINED=0`、`RESULT_PIPELINED=0`、`EARLY_LOAD=0`，空请求和完成缓冲可直通；实际 Load 完成唤醒配合 RR 边沿保存完成值，隔断 Cache→EX AGU→消歧→Cache 的路径。REGISTER_STORE_RESULT 使 Store 在地址/数据记录入 SQ 后报告完成。STORE_LOOKAHEAD 在前一笔提交写完成当拍预览下一笔 FIFO Store，允许连续写握手；完成身份仍属于前一笔。已缓冲 Store 的写载荷来自 SQ，不经过当前 AGU 旁路。

ROB 同样新增 `EARLY_STORE_COMMIT=0`，必须与 LSU 一致。开启且 BUFFER_STORES=1 时，RAM Store 在头部授权边沿进入提交 FIFO，st_done_valid 可在该边沿应答，ROB 可同时退休它和允许的后继非 Store。每拍仍只授权一条 Store。SQ 保留到真实写完成，提交 FIFO 跨 squash 保留。MMIO 仍等待自身真实写响应，不提前退休或退出。

### 21.3 Cache 与预取

DCache 新增 `HIT_UNDER_MISS=0`，顶层与 `REFILL_HITS` 均开启。同一回填行已返回的字可独立响应；逐字回填没有占用 SRAM 的周期可接收一个额外 Load 探测其他有效行。额外命中与原回填响应冲突时保存命中数据；额外 miss 保存请求身份，原回填安装后重试。开始替换时使受害行失效，防止回填中读取正在覆盖的旧数据。响应可不按接受顺序返回，始终使用原 `{gen,id}`。

DCache 新增 `STORE_PIPELINE=0`，顶层开启：Store 命中写一个字库时，可同步探测不同字库的后继请求。同一字库请求仍背压；部分探测 miss 重新读取完整 victim 数据，脏行额外读取阶段保留首次探测取得的 tag，避免从未使能的同步 tag SRAM 采集无效输出。

Cache 请求锁存的地址、数据、身份和类型按小组分发接受使能，保持原握手边沿和有效载荷。单发射 RR 捕获使能同样按 32 位载荷块与两路操作数分别分发。当前与前一拍完成的操作数转发匹配按 16 位输出块分发，分支与普通执行使用独立控制副本；取指输出 FIFO 按 16 位载荷块分发写使能。这些分组不增加寄存级或改变握手。

Cache 与预取缓冲的单字读取按每 4 位输出分发字索引，覆盖普通命中、hit-under-miss、bulk 返回、回填行已返回字及脏行写回，限制索引位驱动整个 Cache line 多路选择器的扇出。握手、字序和 SRAM 读取边沿保持不变。

写数据按字广播并局部选择，写掩码选择真正修改的 SRAM 字库，避免将单字先移位到整行产生高扇出控制。整行回填仍使用分组选择。

`data_prefetch` 新增 `TARGETED_INVALIDATE=0` 及输入 `write_addr[31:0]`。顶层开启后，外部写握手仅使相同 Cache line 的预取快照失效；无关地址保留。受影响的在途预取标记丢弃，排空后才复用槽。默认 0 保留所有预取快照失效的行为。

当前预测器新增 `GLOBAL_HISTORY=0`、`BTB_RAM=0`，顶层 HISTORY_BITS=8、GLOBAL_HISTORY=1、BTB_RAM=1。BTB tag、目标和条件类型存入连续读取的独立 SRAM；刚训练的载荷旁路覆盖同步 SRAM 写后读间隙，预测不增加一级延迟。单解析 lane 的 SRAM 写数据是不依赖写有效位的预览，并按每 8 个 BTB word 分组分发；写使能独立控制实际更新。备用方向表使用 PC XOR 已解析条件分支的全局历史索引，保留 bimodal 表与选择器；关闭该参数仍使用各 BTB 项的局部历史。

ALU 和 LSU 的 32 位加法使用 `word_adder(a[31:0], b[31:0], carry_in, sum[31:0])`，计算 `(a+b+carry_in) mod 2^32`。每 4 位一个局部加法单元，8 组间采用并行前缀进位；保留组边界以限制映射后的串行进位深度。无寄存器、无协议延迟，原载荷语义保持。

ALU 的无符号大小及相等比较使用组合模块 `word_compare(a[31:0], b[31:0], less, equal)`。8 个 4 位比较器并行工作，最高不同组决定大小；有符号比较先比较符号位。`word_adder` 和 `word_compare` 都已通过全输入 SAT 等价证明。

LSU 新增 `BYPASS_STORE_RESULTS=0`，顶层开启：RESULT_PIPELINED=1 时，空结果缓冲可直通已登记地址/数据的 Store 完成；目的和值为语义零，背压时仍锁存结果。该参数只改变 RESULT_PIPELINED=1 的空缓冲 Store 完成路径；当前顶层 RESULT_PIPELINED=0。

LSU 新增 `SPEC_READ_PREVIEW=0` 及 `read_exec_valid` 输入，顶层接 `single_issue.mem_exec_preview_valid`。开启时 RAM 读请求预览不依赖当拍 squash；实际执行、队列更新和完成仍受 squash 过滤。同拍被取消的已接受读按原 `{gen,id}` 排空并归还额度，不能写复用槽；未接受的取消预览不能留在 offer 缓冲。非 RAM 读仍不出外部请求。默认 0 时忽略该输入，保持原 exec_valid 资格。

### 21.4 验证状态

当前版本 v19 在 Docker 中顺序运行，测试与综合不重叠，语言模式为 SystemVerilog 2005。保持 I=D=1、W=C=2；性能仿真断言每拍实际发射数不超过 1。

本批次单发射转发/背压/取消三种配置均通过，取指定向检查覆盖 D=1/2/4、读额度和分支位置。日志：`build/tier2/v19-directed.log`、`build/tier2/v19-branch.log`。此前 LSU 返回代际、取消预览、Store 转发和提交缓冲检查通过，日志：`build/tier2/v18-directed.log`。

六项原性能程序采用 LATENCY=10 与原动态指令数，输出均正确。IPC 报告：`build/tier2/single-v19/profile.json`；其中源码 SHA-256 已与当前源码核对一致。

| 程序 | 周期 | IPC |
|---|---:|---:|
| perf_median | 9081 | 0.7665 |
| perf_multiply | 24124 | 0.9004 |
| perf_qsort | 188216 | 0.7433 |
| perf_rsort | 212069 | 0.9229 |
| perf_towers | 6715 | 0.7860 |
| perf_vvadd | 5781 | 0.7826 |
| 几何平均 | — | **0.8142** |

原 Tier 2 门槛为 0.845，本轮按用户要求放宽到 0.8；频率须达到 200 MHz，面积须不超过 18,000 µm²。当前 IPC 达标。v19 的 `make synth SYNTH_OUT=build/tier2/single-v19/synth` 成功完成：面积 **17,984.779 µm²**，估计频率 **172.55 MHz**，最小周期 **5.7953 ns**，5.0 ns 约束的最差建立裕量 **-0.7951 ns**。面积达标，200 MHz 时序未达标，因此本版尚未满足全部放宽要求。报告：`build/tier2/single-v19/synth/opt/report.txt`、`report.json`、`timing.rpt`；综合输入 SHA-256 已与当前 RTL 核对一致。当前最差路径终点为重命名 checkpoint SRAM 写数据输入。

此前 v10 完整 19 项正确性程序均通过；当前 v19 尚未重跑完整正确性。本批次仅覆盖上述定向与性能验证，不得将此前版本的全套正确性结果视为本版的完整验证。
