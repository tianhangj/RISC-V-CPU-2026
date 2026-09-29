# RV32IM 无缓存乱序核接口规范

版本：v1.2。本文定义成员 A、B 的实现接口；与 `plan.md` 冲突时以本文为准。外部接口遵守 [README](README-ZH.md) 和 [AXI 规范](docs/axi4-lite.md)。

## 1. 架构与实现边界

- RV32IM、乱序发射、按序提交、物理寄存器重命名；无缓存、Store 转发、投机访存消歧、分支检查点或预测表。
- 默认预测下一 PC 为 PC+4；接口允许预测到任意 4 字节对齐的 32 位地址，退休时纠正误预测。
- 正确路径指令受支持且访问合法；所有路径地址按访问宽度自然对齐。正确路径取指、Load 访问 RAM，Store 访问 RAM 或执行合法退出写。无 CSR、特权陷入或精确异常状态。
- Store 仅在 ROB 头部获得外部写授权。RAM Load 可越过地址已知且字节范围不重叠的旧 Store；非 RAM Load 在本地返回零。
- kill 直接取消 CPU 内部推测工作，AXI 桥独立完成已接受事务；桥空闲后恢复重命名映射并重新取指。旧外部事务排空前不创建新工作。
- 接口只携带接收方消费的字段，不提供调试、退休轨迹、断言、运行时一致性检查、超时、重试或配置检查电路。不要求验证基础设施。

无缓存取指每拍最多取得一个 32 位指令字，与数据读取共享总线。错误路径可以占用内部资源和读取 RAM，但不能改变已提交寄存器、内存或外设状态，不能触发退出。队列满时背压，正确性不依赖错误路径长度或误预测次数的上限。未知编码转 NOP、非 RAM 读门控、Store 授权和 squash 是这一功能要求的一部分。

| 模块 | 主责 | 职责 |
|---|---|---|
| student_top / fetch / decode | A | 接线、取指、译码 |
| rename / prf / rob / branch_ctrl | A | 重命名、寄存器、顺序提交、恢复 |
| iq_alu / iq_mem / issue_sched | B | 就绪跟踪、候选选择、操作数读取 |
| alu × I / mul_div / wb_arb | B | 执行、完成仲裁、定向写回 |
| lsu / axi_bridge | B | AGU、LQ/SQ、Store 授权执行、总线 |

A 维护公共参数与位布局；类型采用普通 packed 向量，不要求 package/import。

## 2. 参数与线网约定

| 参数 | 默认 | 取值 |
|---|---:|---|
| ISSUE_WIDTH（I） | 2 | 1/2/4，全核每拍发射上限 |
| DISPATCH_WIDTH（D） | 2 | 1/2/4 |
| WB_WIDTH（W） | 2 | 1/2/4，每拍接受完成数 |
| COMMIT_WIDTH（C） | 2 | 1/2/4 |
| ROB_DEPTH（R） | 32 | 2 的幂，至少 8，且不小于 I/D/W/C |
| PRF_SIZE（P） | 64 | 至少 32+D |
| IQ_ALU_DEPTH / IQ_MEM_DEPTH | 16 / 16 | 2 的幂，至少 D |
| LQ_DEPTH / SQ_DEPTH | 8 / 8 | 2 的幂，至少 D |
| FETCH_QUEUE_DEPTH（F） | 16 | 2 的幂，至少 D |
| IFETCH_OUTSTANDING | 8 | 1–16，不大于 F |
| LOAD_OUTSTANDING | 8 | 1–16，不大于 LQ_DEPTH |
| AXI_RD_OUTSTANDING | 16 | 1–16，IF/LD 共享 |
| RESET_PC | 32'h00000000 | RAM 内，4 字节对齐 |

XLEN 固定 32，不作为参数。最多一笔未完成写。参数满足上表是集成前提，不增加参数合法性检查。

定义 `IDX(N)=max(1,ceil(log2(N)))`、`CNT(N)=max(1,ceil(log2(N+1)))`。`RW=IDX(R)`、`PW=IDX(P)`、`LIDW=IDX(LQ_DEPTH)`、`SIDW=IDX(SQ_DEPTH)`、`FIDW=IDX(F)`、`MIDW=max(LIDW,SIDW)`。

ROB 身份只使用 `RW` 位槽索引，不携带 wrap/epoch。活跃项的年龄为 `(index-head) mod R`，ROB 自身用占用计数区分满/空。正常执行中指令完成后才能退休，槽位从退休下一拍复用；kill 后所有内部结果取消，外部事务排空前不重新分配，因此不需要代际字段。

时序模块使用 clock 上升沿及高电平同步 reset。复位只初始化有效位、指针、计数和必要架构状态，不清空无效载荷。

类型字段按表中顺序从高位到低位打包，无 padding；lane 0 在扁平总线最低位。有序包 lane 0 最老。无效 lane、不适用字段和空槽内容不要求清零；只更新有效位及必要控制状态。语义零值（p0、不写目的时的 pdst=0、非 RAM Load 的结果零）仍必须生成。

- **保持型通道**：valid/ready/payload，在上升沿 valid&&ready 时接收；阻塞期间有效载荷保持。valid 不组合依赖 ready。
- **事件**：valid/payload，无 ready；接收方已具备空间，当拍全部接收。派遣、完成、唤醒、退休更新、读响应、Store 授权和写完成使用事件。
- **预览**：容量、候选、分配槽号可以每拍变化，仅在选中或派遣时采样。

kill 可取消内部推测请求、结果和读响应；已被桥接受的请求以及外部 AXI VALID 不能取消。控制优先级为 reset > kill > restore > 正常事件；触发 kill 的指令自身退休更新是明确例外，必须保留。

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

ROB 单独保存 2 位 `kind`：0=普通，1=控制流，2=Load，3=Store。ROB 不保存 op，kind 用于提交、下一 PC 更新和 Store 授权；LSU 分配载荷中的 is_store 仅用于选择 LQ/SQ。

### 3.2 定向载荷

不定义完整的 renamed_uop 透传包。Rename 将同一条指令投影为不同接收方的载荷；公共字段共享产生逻辑，不为每份投影重复设置存储。

| 类型 | 字段（高位到低位） |
|---|---|
| `fetch_packet_t` | `pc:32, inst:32, pred_npc:32` |
| `decoded_uop_t` | `pc:32, pred_npc:32, op:6, rs1:5, rs2:5, rd:5, imm:32` |
| `rob_alloc_t` | `npc:32, mispred:1, rd:5, pdst:PW, kind:2, sq_id:SIDW` |
| `alu_iq_t` | `rob:RW, op:6, pdst:PW, ps1:PW, ps2:PW, pc:32, imm:32` |
| `mem_iq_t` | `rob:RW, mem_op:3, mem_id:MIDW, ps1:PW, ps2:PW, imm:32` |
| `mem_alloc_t` | `is_store:1, mem_id:MIDW, rob:RW, pdst:PW` |
| `alu_exec_t` | `rob:RW, op:6, pdst:PW, pc:32, imm:32, rs1_value:32, rs2_value:32` |
| `mul_exec_t` | `rob:RW, mul_op:3, pdst:PW, rs1_value:32, rs2_value:32` |
| `mem_exec_t` | `mem_op:3, mem_id:MIDW, base:32, imm:32, data:32` |
| `alu_result_t` | `rob:RW, pdst:PW, value:32, npc:32` |
| `result_t` | `rob:RW, pdst:PW, value:32` |
| `rob_done_t` | `rob:RW, npc:32` |
| `reg_commit_t` | `rd:5, pdst:PW` |
| `if_req_t` | `id:FIDW, addr:32` |
| `if_rsp_t` | `id:FIDW, data:32` |
| `ld_req_t` | `id:LIDW, addr:32` |
| `ld_rsp_t` | `id:LIDW, data:32` |
| `write_req_t` | `addr:32, data:32, strb:4` |

`inst` 到 Decode 为止。Decode 输出的 rs1/rs2 对不使用的源置 0，rd 对无目的寄存器的指令置 0；不携带 uses_rs、writes_rd。Rename 将无目的写编码为 pdst=0，后续以 pdst!=0 产生 PRF 写和唤醒，不携带 rd_we。

ROB 分配项中的 npc 为一个复用字段：控制流指令填 pred_npc，mispred 初值为 0；其他指令填 PC+4，mispred 在 Rename 计算为 pred_npc!=(PC+4)。控制流完成时 ROB 比较实际 npc 与原预测值，将 npc 覆盖为实际值并设置 mispred。退休只读取这一个恢复地址和一个不匹配位，不再同时保存 PC、预测 PC 和实际 PC。

pc/imm 仅进入需要计算它们的执行路径。ALU IQ 接收所有非访存操作，包括乘除；MEM IQ 只接收 mem_op、imm、源物理编号和队列身份。发射时读取 ps1/ps2 后不再携带物理源编号；乘除入口不携带 pc/imm，AGU 入口不携带 ROB/目的编号，后两者已保存在 LQ/SQ。

`mem_id` 为 LQ/SQ 槽号的联合字段，由 is_store 或 mem_op 限定，高位不足时补零。槽号 0 也是正常槽号，不用 0 表示无效。ROB 只携带 Store 所需的 SIDW 位 sq_id；Load 完成后即可释放 LQ，不需向 ROB 传递 LQ 槽号。

### 3.3 位宽

| 常量 | 公式 | 默认位数 |
|---|---|---:|
| `FETCH_BITS` | 32 + 32 + 32 | 96 |
| `DECODE_BITS` | 32 + 32 + 6 + 5 + 5 + 5 + 32 | 117 |
| `ROB_ALLOC_BITS` | 32 + 1 + 5 + PW + 2 + SIDW | 49 |
| `ALU_IQ_BITS` | RW + 6 + PW + PW + PW + 32 + 32 | 93 |
| `MEM_IQ_BITS` | RW + 3 + MIDW + PW + PW + 32 | 55 |
| `MEM_ALLOC_BITS` | 1 + MIDW + RW + PW | 15 |
| `ALU_EXEC_BITS` | RW + 6 + PW + 32 + 32 + 32 + 32 | 145 |
| `MUL_EXEC_BITS` | RW + 3 + PW + 32 + 32 | 78 |
| `MEM_EXEC_BITS` | 3 + MIDW + 32 + 32 + 32 | 102 |
| `ALU_RESULT_BITS` | RW + PW + 32 + 32 | 75 |
| `RESULT_BITS` | RW + PW + 32 | 43 |
| `ROB_DONE_BITS` | RW + 32 | 37 |
| `REG_COMMIT_BITS` | 5 + PW | 11 |
| `IF_REQ_BITS` | FIDW + 32 | 36 |
| `IF_RSP_BITS` | FIDW + 32 | 36 |
| `LD_REQ_BITS` | LIDW + 32 | 35 |
| `LD_RSP_BITS` | LIDW + 32 | 35 |
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

Fetch 预留一个槽后保存 pc/pred_npc，将下一个取指 PC 更新为所采用的 pred_npc。默认选择 PC+4；任意其他对齐预测值必须同时用于记录和实际取指流。每拍至多创建一个槽，已有请求 offer 被背压时不再创建新 offer 或重复推进 PC。PC 加法按模 2^32 执行。

RAM 内槽发送 `if_req` 保持型请求，桥接受后增加未完成读数；`if_rsp_valid` 是无 ready 的响应事件，Fetch 直接写入预留槽并减少计数。槽位在输出包被消费后释放。RAM 外 PC 不发 AR，原槽填 inst=0 并标记就绪，不占读额度。

最老且按预测流连续就绪的至多 D 个槽形成 fetch_packet 包，PC 不要求连续。valid 时 count 为 1..D，整包接受；背压期间 count 和载荷保持。Decode 纯组合转换：decode_valid=fetch_valid、fetch_ready=decode_ready，count 原样传递。Rename 缓冲已接收的包。

Decode 生成已扩展的 imm：I/S/B/J 符号扩展，U 为 inst[31:12]<<12。LUI、AUIPC、JAL 不使用寄存器源；JALR、立即数运算和 Load 使用 rs1；条件分支、寄存器运算、Store、M 扩展使用 rs1/rs2。只有具有架构目的的操作保留 rd。op 决定 ALU 输入选择、访存大小和符号扩展，不重复传递这些控制位。

不支持或未知的指令编码（包括零填充、CSR、FENCE、FENCE.I、ECALL、EBREAK）输出 op=NOP、rs1=rs2=rd=0，不申请目的物理寄存器或访存槽。正确路径不会出现这些编码；此处理使错误预测进入任意 RAM 内容后仍能继续执行和 squash。

## 6. Rename 与原子派遣

### 6.1 分配预览

| 来源 → Rename | 信号 | 含义 |
|---|---|---|
| ROB | rob_free、rob_tail | 可分配项数、单个尾索引；lane k 的 ROB 索引为 (rob_tail+k) mod R |
| 两个 IQ | alu_iq_free、mem_iq_free | 周期开始时空闲项数 |
| LSU | lq_free、sq_free | 周期开始时空闲项数 |
| LSU | lq_alloc_id[D]、sq_alloc_id[D] | 从空闲位图按编号递增给出候选槽 |

ROB 不输出可由尾索引推导的 D 份标签。LQ/SQ 完成顺序可以不同于分配顺序，保留空闲位图和候选槽列表。

### 6.2 派遣投影

Rename 保留一个译码包缓冲和一个派遣 offer。根据全部容量选取最大可容纳前缀，锁存 count、ROB 索引、物理目的和访存槽候选；未选后缀留在译码缓冲。offer 只在 disp_valid&&disp_ready 时原子生效，背压期间内容不变。

| 投影 | 接收方 | 数据 |
|---|---|---|
| disp_rob[D] | ROB | rob_alloc_t |
| disp_alu[D] | ALU IQ | alu_iq_t，仅非访存 lane 有意义 |
| disp_mem[D] | MEM IQ | mem_iq_t，仅访存 lane 有意义 |
| disp_lsq[D] | LSU | mem_alloc_t，仅访存 lane 有意义 |
| disp_src1_ready/disp_src2_ready[D] | 两个 IQ | 源就绪侧带，在对应派遣事件采样 |

顶层根据 disp_rob.kind 统计 need_alu/need_mem/need_lq/need_sq；统一 fire 为 `disp_valid && disp_ready`，disp_ready 由 run、!kill 及四类队列和 ROB 的容量满足条件产生。ROB 接收 disp_fire、disp_count 和 disp_rob；IQ 接收按类别与 fire 生成的逐 lane disp_valid；LSU 接收同样的访存 lane 事件。无效 lane 载荷不消费，不为 LSU 或 IQ 传递全核 count 和其他模块的投影。

Rename 按包内顺序读取临时推测 RAT 的源映射，为非零 rd 分配最低编号空闲 pdst，再更新临时 RAT；后续 lane 读取更新后的映射。ps1/ps2=0 时源总是就绪。只有 fire 才更新推测 RAT、空闲表和分配状态。offer 中编号保持，源就绪侧带读取实时 ready 表并合入当拍唤醒；若源来自同包较老 lane 的新目的则未就绪。

不保存或传递 old_pdst。退休时 Rename 按 lane 从老到新读取提交 RAT[rd]、释放该旧映射，再将提交 RAT[rd] 更新为 pdst；同拍同 rd 的多次退休依次操作，能直接得到正确的旧映射。reg_commit_valid 仅在该退休 lane 写寄存器时为 1，其余 lane 无事件。

当拍释放的物理寄存器和队列槽从下一拍起参与分配，不做容量组合穿透。复位推测/提交 RAT 为 xN→pN；p0..p31 就绪，其他物理寄存器空闲且未就绪。p0 固定为零且不分配为目的。

## 7. IQ、发射与 PRF

IQ 仅接收自己的派遣投影及 `wake_valid[W]/wake_pdst[W]`，不接收结果数据、ROB 完成信息、控制流目标或退休信息。各 IQ 存储本地有效位与源就绪位，每拍给出至多 I 个按 ROB 年龄排序的就绪候选。Rename 的物理 ready 表在派遣时清新目的位，在 wake_valid 时置对应目的位；IQ 在派遣时采样源就绪，随后按源物理编号匹配唤醒。

候选接口为 cand_valid[I]、cand_uop[I]、cand_take[I]。外部不传 cand_slot；IQ 内部保存每个候选 lane 对应的槽号，在 cand_take 上升沿移除该槽。候选为组合预览，可每拍改变；同一槽只出现一次。

issue_sched 合并两组候选，按 ROB 年龄选择可容纳的最老项，每拍总 take 数不超过 I。它保留 I 个 ALU 入口、一个 MULDIV 入口、一个 AGU 入口，各深度 1；周期开始时为空的入口可接收新项。ALU IQ 的 op=38..45 投影到 mul_exec_t，其他项投影到 alu_exec_t；MEM IQ 投影到 mem_exec_t。

PRF 有 2I 个组合读口，选择序号 k 使用读口 2k/2k+1，操作数与执行投影一起在 take 边沿锁存。PRF 有 W 个写口，write_valid/pdst/value 只驱动对应写入。p0 读零，不写入；同址读写组合旁路返回当拍写值。已在 IQ 中的依赖收到唤醒后最早下一拍候选。

PRF 复位只需将 p1..p31 的初始架构值设零；p0 可直接用常量实现，其他数据不复位。恢复只重建映射和 ready/free 位，不清 PRF 数据。

## 8. 执行与定向完成

### 8.1 执行单元

ALU 使用一项结果缓冲，接收请求后最早下一拍 result_valid；满时背压。ALU 根据 op 使用寄存器值、PC 或 imm，计算 32 位结果。NOP 正常产生一次完成，pdst=0。

分支实际下一 PC：条件成立为 PC+imm，否则 PC+4；JAL 为 PC+imm，JALR 为 (rs1+imm)&~1。JAL/JALR 的寄存器结果为 PC+4。alu_result.npc 只在控制流指令有意义，ROB 根据自己的 kind 消费，不传 branch_valid。整数结果截断为 32 位，移位量使用低 5 位，有符号比较和右移使用有符号解释。

乘除单元一次处理一条指令，结果保持至接收。延迟由实现决定，其结果只携带 ROB 索引、pdst 和 value，不携带下一 PC。

| 情况 | 结果 |
|---|---|
| MUL | 乘积低 32 位 |
| MULH / MULHSU / MULHU | 分别按有符号×有符号、有符号×无符号、无符号×无符号求 64 位乘积的高 32 位 |
| DIV/DIVU 除零 | `0xffffffff` |
| REM/REMU 除零 | 原被除数 |
| DIV `0x80000000 / 0xffffffff` | `0x80000000` |
| 同上 REM | 0 |
| 正常有符号除法 | 商向零截断，非零余数符号与被除数一致 |

ALU、MULDIV、AGU 和结果缓冲在 kill 当拍屏蔽正常握手，边沿清有效/忙状态并终止内部运算；以后不再产生旧结果。乘除实现采用可由 kill 清除的本地状态机，不为执行单元设置排空确认或等待完成后丢弃的备用路径。

### 8.2 完成仲裁与消费者

wb_arb 接收 I 路 alu_result_t、一条乘除 result_t 和一条 LSU result_t。按轮询指针扫描 I+2 个源，最多接受 W 个，每源每拍至多一个；指针移至最后接收源之后，无接收则保持。完成 lane 压紧到低位；源 ready 表示这条结果当拍被接受，未选源保持结果。

| 输出 | 接收方 | 内容 |
|---|---|---|
| done_valid[W]、done_payload[W] | ROB | rob_done_t；非 ALU 源的 npc 不消费 |
| write_valid[W]、write_pdst[W]、write_value[W] | PRF | 当完成 pdst!=0 时写入 |
| write_valid[W]、write_pdst[W] 的分支线 | Rename、两 IQ 的 wake 端口 | 仅物理目的和有效位，数据不广播 |

完成、PRF 写与唤醒在同一接收边沿发生，无下游 ready。无寄存器写的 NOP、分支或 Store 仍使用完成 lane；done_valid 与 write_valid 分开，不将 pdst=0 的完成漏掉。ROB 根据 done_payload.rob 索引更新 done，只有 kind=控制流时消费 npc。

kill 当拍不产生 done_valid/write_valid；仲裁器只清轮询状态，不保留结果副本，不输出排空确认。

## 9. ROB 与退休

ROB 每项只保存 rob_alloc_t 和 done、Store 授权/响应状态。不保存原指令、源寄存器、执行操作码、旧目的映射或调试 PC。

普通指令每拍退休至多 C 条连续已完成且 mispred=0 的前缀。遇到未完成、控制流、Store 或 mispred=1 的项停止；较老普通前缀先退休，特殊项下一拍到头部后处理。当拍完成最早下一拍退休。

控制流或 mispred=1 的指令仅在头部单独退休；mispred=1 时同拍产生 recover_valid/recover_pc，其他退休 lane 无效。所有类别都检测预测不匹配，包括普通运算、NOP、Load 和 Store，因此错误预测出自非控制流指令时也不会让错误路径退休。

Store 在头部且执行完成后发出一次 `st_start_valid/st_start_id` 授权事件。LSU 总能接收：SQ 已预留，且前一获授权 Store 已完成才能轮到本项。不设 ready，不携带 ROB 标签。ROB 记录已授权，收到无载荷 `st_done_valid` 后记已响应，最早下一拍单独退休；若其 mispred=1，在这次退休时重定向，不能提前 kill 该 Store。

ROB 只向 Rename 发出 `reg_commit_valid[C]/reg_commit_payload[C]`，载荷为 rd/pdst；仅实际写寄存器的退休 lane 有效，允许空洞。LSU 不接收退休广播。ROB 本地释放退休槽并更新 head/count，尾索引只在派遣时更新。

恢复事件仅根据周期开始时的 ROB 状态生成，不依赖 kill。kill 当拍保留触发指令的寄存器提交事件，并清空其后的全部年轻 ROB 状态。

## 10. LSU 与槽位回收

LSU 由派遣事件按指定 mem_id 分配 LQ/SQ，保存 ROB 索引；LQ 还保存 pdst。AGU 请求包含 mem_op、mem_id、base/imm/data，不再重复携带 ROB/pdst。

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

RAM Load 扫描更老 SQ：旧 Store 地址未知或同字节重叠且未完成写时等待；地址不同或字节掩码不相交可发送。ld_req 为保持型通道，桥接收后计入读额度；ld_rsp 是无 ready 事件，数据直接进入已预留 LQ，减少读额度。WB 背压不会占用桥内响应缓冲。

非 RAM Load 不发请求，在其 LQ 产生零值并标记数据就绪，不占读额度，不等待 Store 消歧或外部响应。这使任意错误路径 Load 不访问 MMIO，也不会等待不存在的结果。

LSU 只有一个 result_t 输出缓冲，仅在周期开始时为空时填入；从数据就绪的 LQ 和地址/数据就绪的 SQ 中选最老且完成未发送的项；载荷从队列记录取 ROB/pdst，Store 的 pdst=0。完成被 wb_arb 接收后，Load 立即释放 LQ；Store 标记执行完成已发送并继续保留 SQ。LQ 不必等退休，已返回的读事务不存在迟到响应。

SQ 接收头部 st_start_id 后建立仅含 addr/data/strb 的 st_req；同一时刻只有一个授权 Store。桥发出 st_rsp_valid 时，LSU 同拍向 ROB 发出 st_done_valid，并在边沿释放对应 SQ。Store 已完成外部写后即可解除所有相关 Load 依赖，不必等待下一拍 ROB 退休；等待 AW/W 接受不能代替等待 B。

错误路径 Store 不会取得头部授权，任意地址仅保留在 SQ。正确路径合法退出 SW 也遵守相同授权及 AW/W/B 协议。LSU 不检查授权地址或标签的一致性，不为冗余核对传递副本。

kill 清空 LQ/SQ、请求 offer、完成缓冲、未完成读计数和授权状态；尚在外部的旧读由桥独立排空，LSU 不保留 tombstone 或旧事务跟踪表。触发恢复时没有未完成的授权 Store。

## 11. AXI 桥

### 11.1 读通路

IF/LD 请求为独立保持型通道，分别使用 FIDW/LIDW 位 id，不扩成统一宽度。共享最多 AXI_RD_OUTSTANDING 笔请求；两者同时有效时轮询，复位 IF 优先，每次接收后优先另一方，每拍至多接受一个。桥本地记录 source、对应槽号和 AR 所需地址。

已接受请求按顺序发送 AR，arvalid/addr 保持至 arready。请求描述符保留到对应 R 握手；AXI 无 ID，R 匹配最老的已发 AR 请求。同拍刚握手的 AR 最早下一拍才接受其 R，符合外部从机延迟约定。

Fetch 和 LSU 为每个读预留了接收槽，因此不提供 if_rsp_ready/ld_rsp_ready，也不需要桥内返回数据队列。存在已发 AR 的队首事务时桥接收 R；run=1 时在该握手拍向对应客户端发送一次 id/data 事件，run=0 时直接丢弃。两种情况都释放该桥槽，不能因 CPU 停止而阻塞 R。

### 11.2 写通路

桥只有一个写槽，st_req 为 addr/data/strb 保持型通道，不携带事务 ID。接受后分别维护 aw_pending、w_pending；AW 与 W 独立驱动并各自保持至握手。两者完成后接收 B，`st_rsp_valid=bvalid&&bready` 为无载荷完成事件，LSU 无需 ready；桥在该边沿释放写槽。不保存 bresp 或额外写响应缓冲。

### 11.3 停止与排空

桥只接收 run 控制，不接 kill/restore。run=0 时停止接受新请求，继续发送已经接受的 AR/AW/W、消费 R/B；旧读响应在桥内丢弃，不送回已清空的 CPU 队列。

`idle` 表示读事务队列和写槽均空、无待握手外部 VALID。它是唯一的恢复排空确认。读槽只在 R 消费后释放，写槽只在 B 消费后释放，因此 idle 不会漏掉未发送或尚未返回的承诺事务。

## 12. 恢复控制与必要扇出

| 状态 | run | 行为 |
|---|---:|---|
| RUN | recover_valid=0 时为 1，否则为 0 | 正常创建工作，recover_valid 产生一拍 kill 并锁存 recover_pc |
| DRAIN | 0 | 等待 bridge_idle；CPU 内部已被 kill 清空 |
| RESTORE | 0 | restore=1 一拍，重建映射并设置 Fetch PC，然后回 RUN |

| 模块 | 恢复输入 | 处理 |
|---|---|---|
| Fetch | run、kill、restore、restart_pc | kill 清槽/offer/输出/读计数；restore 设置 PC；仅 run 时创建新槽 |
| Rename | run、kill、restore | kill 清缓冲并保留触发指令的提交更新；restore 从更新后的提交 RAT 重建推测 RAT 和 free/ready |
| ROB | kill | 清空年轻项、头尾/计数和 Store 控制；触发指令自身提交仍生效 |
| 两 IQ、issue_sched | kill | 清有效位和请求入口；kill 当拍不 take 或发送执行请求 |
| ALU、MULDIV、LSU、wb_arb | kill | 取消计算/缓冲并屏蔽完成与写回 |
| AXI bridge | run | 低时履行旧事务并丢弃读结果，输出 idle |
| Decode、PRF | 无 | Decode 组合工作，PRF 保留已提交数据 |

run 只驱动 Fetch、Rename、桥及顶层派遣门控；restore 只驱动 Fetch 和 Rename。不再给 IQ、ROB、执行单元和仲裁器发送 run/restore，也没有逐模块 flush_done 或确认向量。

RESTORE 将提交 RAT 中映射的物理寄存器置已分配/就绪，其余置空闲/未就绪，始终保留 p0。JAL/JALR 或普通误预测指令的退休更新先完成，再用于恢复。桥 idle 前 run 一直为 0，新标签和队列槽不能与外部旧事务重叠。

任意数量错误路径指令可以按资源容量执行并被 squash；资源满只阻止新派遣，不阻止旧指令完成、头部提交或 kill。kill 不等待年轻依赖链完成。进展依赖执行单元和外部总线最终完成已接受工作，不添加超时兜底。

## 13. 模块端口声明

以下声明仅定义连接，模块体留空。参数中的派生位宽只用于声明，由架构参数计算，不独立覆盖。与载荷无关的队列参数不传播到其他模块。

### 13.1 `student_top`

```systemverilog
module student_top #(
    parameter integer ISSUE_WIDTH = 2,
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer WB_WIDTH = 2,
    parameter integer COMMIT_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer IQ_ALU_DEPTH = 16,
    parameter integer IQ_MEM_DEPTH = 16,
    parameter integer LQ_DEPTH = 8,
    parameter integer SQ_DEPTH = 8,
    parameter integer FETCH_QUEUE_DEPTH = 16,
    parameter integer IFETCH_OUTSTANDING = 8,
    parameter integer LOAD_OUTSTANDING = 8,
    parameter integer AXI_RD_OUTSTANDING = 16,
    parameter [31:0] RESET_PC = 32'h00000000
) (
    input logic clock,
    input logic reset,
    output logic [32-1:0] araddr,
    output logic arvalid,
    input logic arready,
    input logic [32-1:0] rdata,
    input logic [2-1:0] rresp,
    input logic rvalid,
    output logic rready,
    output logic [32-1:0] awaddr,
    output logic awvalid,
    input logic awready,
    output logic [32-1:0] wdata,
    output logic [4-1:0] wstrb,
    output logic wvalid,
    input logic wready,
    input logic [2-1:0] bresp,
    input logic bvalid,
    output logic bready
);
endmodule
```

### 13.2 `fetch`

```systemverilog
module fetch #(
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer FETCH_QUEUE_DEPTH = 16,
    parameter integer IFETCH_OUTSTANDING = 8,
    parameter [31:0] RESET_PC = 32'h00000000,
    parameter integer FIDW = (FETCH_QUEUE_DEPTH > 1) ? $clog2(FETCH_QUEUE_DEPTH) : 1,
    parameter integer DCW = $clog2(DISPATCH_WIDTH + 1),
    parameter integer FETCH_BITS = 32 + 32 + 32,
    parameter integer IF_REQ_BITS = FIDW + 32,
    parameter integer IF_RSP_BITS = FIDW + 32
) (
    input logic clock,
    input logic reset,
    input logic kill,
    input logic run,
    input logic restore,
    input logic [32-1:0] restart_pc,
    output logic if_req_valid,
    input logic if_req_ready,
    output logic [IF_REQ_BITS-1:0] if_req_payload, // if_req_t
    input logic if_rsp_valid,
    input logic [IF_RSP_BITS-1:0] if_rsp_payload, // if_rsp_t
    output logic fetch_valid,
    input logic fetch_ready,
    output logic [DCW-1:0] fetch_count,
    output logic [DISPATCH_WIDTH*FETCH_BITS-1:0] fetch_packet // fetch_packet_t × D
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
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer WB_WIDTH = 2,
    parameter integer COMMIT_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer IQ_ALU_DEPTH = 16,
    parameter integer IQ_MEM_DEPTH = 16,
    parameter integer LQ_DEPTH = 8,
    parameter integer SQ_DEPTH = 8,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1,
    parameter integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1,
    parameter integer MIDW = (LIDW > SIDW) ? LIDW : SIDW,
    parameter integer DCW = $clog2(DISPATCH_WIDTH + 1),
    parameter integer ROB_CW = $clog2(ROB_DEPTH + 1),
    parameter integer AIQ_CW = $clog2(IQ_ALU_DEPTH + 1),
    parameter integer MIQ_CW = $clog2(IQ_MEM_DEPTH + 1),
    parameter integer LQ_CW = $clog2(LQ_DEPTH + 1),
    parameter integer SQ_CW = $clog2(SQ_DEPTH + 1),
    parameter integer DECODE_BITS = 32 + 32 + 6 + 5 + 5 + 5 + 32,
    parameter integer ROB_ALLOC_BITS = 32 + 1 + 5 + PW + 2 + SIDW,
    parameter integer ALU_IQ_BITS = RW + 6 + PW + PW + PW + 32 + 32,
    parameter integer MEM_IQ_BITS = RW + 3 + MIDW + PW + PW + 32,
    parameter integer MEM_ALLOC_BITS = 1 + MIDW + RW + PW,
    parameter integer REG_COMMIT_BITS = 5 + PW
) (
    input logic clock,
    input logic reset,
    input logic kill,
    input logic run,
    input logic restore,
    input logic decode_valid,
    output logic decode_ready,
    input logic [DCW-1:0] decode_count,
    input logic [DISPATCH_WIDTH*DECODE_BITS-1:0] decode_uop, // decoded_uop_t × D
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
    output logic [DISPATCH_WIDTH*ROB_ALLOC_BITS-1:0] disp_rob, // rob_alloc_t × D
    output logic [DISPATCH_WIDTH*ALU_IQ_BITS-1:0] disp_alu, // alu_iq_t × D
    output logic [DISPATCH_WIDTH*MEM_IQ_BITS-1:0] disp_mem, // mem_iq_t × D
    output logic [DISPATCH_WIDTH*MEM_ALLOC_BITS-1:0] disp_lsq, // mem_alloc_t × D
    output logic [DISPATCH_WIDTH-1:0] disp_src1_ready,
    output logic [DISPATCH_WIDTH-1:0] disp_src2_ready,
    input logic [WB_WIDTH-1:0] wake_valid,
    input logic [WB_WIDTH*PW-1:0] wake_pdst,
    input logic [COMMIT_WIDTH-1:0] reg_commit_valid,
    input logic [COMMIT_WIDTH*REG_COMMIT_BITS-1:0] reg_commit_payload // reg_commit_t
);
endmodule
```

### 13.5 `prf`

```systemverilog
module prf #(
    parameter integer ISSUE_WIDTH = 2,
    parameter integer WB_WIDTH = 2,
    parameter integer PRF_SIZE = 64,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1
) (
    input logic clock,
    input logic reset,
    input logic [2*ISSUE_WIDTH*PW-1:0] rd_addr,
    output logic [2*ISSUE_WIDTH*32-1:0] rd_data,
    input logic [WB_WIDTH-1:0] write_valid,
    input logic [WB_WIDTH*PW-1:0] write_pdst,
    input logic [WB_WIDTH*32-1:0] write_value
);
endmodule
```

### 13.6 `rob`

```systemverilog
module rob #(
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer WB_WIDTH = 2,
    parameter integer COMMIT_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer SQ_DEPTH = 8,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1,
    parameter integer DCW = $clog2(DISPATCH_WIDTH + 1),
    parameter integer ROB_CW = $clog2(ROB_DEPTH + 1),
    parameter integer ROB_ALLOC_BITS = 32 + 1 + 5 + PW + 2 + SIDW,
    parameter integer ROB_DONE_BITS = RW + 32,
    parameter integer REG_COMMIT_BITS = 5 + PW
) (
    input logic clock,
    input logic reset,
    input logic kill,
    input logic disp_fire,
    input logic [DCW-1:0] disp_count,
    input logic [DISPATCH_WIDTH*ROB_ALLOC_BITS-1:0] disp_rob, // rob_alloc_t × D
    input logic [WB_WIDTH-1:0] done_valid,
    input logic [WB_WIDTH*ROB_DONE_BITS-1:0] done_payload, // rob_done_t
    output logic [ROB_CW-1:0] rob_free,
    output logic [RW-1:0] rob_tail,
    output logic [RW-1:0] rob_head,
    output logic [COMMIT_WIDTH-1:0] reg_commit_valid,
    output logic [COMMIT_WIDTH*REG_COMMIT_BITS-1:0] reg_commit_payload, // reg_commit_t
    output logic st_start_valid,
    output logic [SIDW-1:0] st_start_id,
    input logic st_done_valid,
    output logic recover_valid,
    output logic [32-1:0] recover_pc
);
endmodule
```

### 13.7 `branch_ctrl`

```systemverilog
module branch_ctrl (
    input logic clock,
    input logic reset,
    input logic recover_valid,
    input logic [32-1:0] recover_pc,
    input logic bridge_idle,
    output logic run,
    output logic kill,
    output logic restore,
    output logic [32-1:0] restart_pc
);
endmodule
```

### 13.8 `iq_alu`

```systemverilog
module iq_alu #(
    parameter integer ISSUE_WIDTH = 2,
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer WB_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer IQ_ALU_DEPTH = 16,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer AIQ_CW = $clog2(IQ_ALU_DEPTH + 1),
    parameter integer ALU_IQ_BITS = RW + 6 + PW + PW + PW + 32 + 32
) (
    input logic clock,
    input logic reset,
    input logic kill,
    input logic [RW-1:0] rob_head,
    input logic [DISPATCH_WIDTH-1:0] disp_valid,
    input logic [DISPATCH_WIDTH*ALU_IQ_BITS-1:0] disp_uop, // alu_iq_t × D
    input logic [DISPATCH_WIDTH-1:0] disp_src1_ready,
    input logic [DISPATCH_WIDTH-1:0] disp_src2_ready,
    input logic [WB_WIDTH-1:0] wake_valid,
    input logic [WB_WIDTH*PW-1:0] wake_pdst,
    output logic [AIQ_CW-1:0] alu_iq_free,
    output logic [ISSUE_WIDTH-1:0] cand_valid,
    output logic [ISSUE_WIDTH*ALU_IQ_BITS-1:0] cand_uop, // alu_iq_t
    input logic [ISSUE_WIDTH-1:0] cand_take
);
endmodule
```

### 13.9 `iq_mem`

```systemverilog
module iq_mem #(
    parameter integer ISSUE_WIDTH = 2,
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer WB_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer IQ_MEM_DEPTH = 16,
    parameter integer LQ_DEPTH = 8,
    parameter integer SQ_DEPTH = 8,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1,
    parameter integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1,
    parameter integer MIDW = (LIDW > SIDW) ? LIDW : SIDW,
    parameter integer MIQ_CW = $clog2(IQ_MEM_DEPTH + 1),
    parameter integer MEM_IQ_BITS = RW + 3 + MIDW + PW + PW + 32
) (
    input logic clock,
    input logic reset,
    input logic kill,
    input logic [RW-1:0] rob_head,
    input logic [DISPATCH_WIDTH-1:0] disp_valid,
    input logic [DISPATCH_WIDTH*MEM_IQ_BITS-1:0] disp_uop, // mem_iq_t × D
    input logic [DISPATCH_WIDTH-1:0] disp_src1_ready,
    input logic [DISPATCH_WIDTH-1:0] disp_src2_ready,
    input logic [WB_WIDTH-1:0] wake_valid,
    input logic [WB_WIDTH*PW-1:0] wake_pdst,
    output logic [MIQ_CW-1:0] mem_iq_free,
    output logic [ISSUE_WIDTH-1:0] cand_valid,
    output logic [ISSUE_WIDTH*MEM_IQ_BITS-1:0] cand_uop, // mem_iq_t
    input logic [ISSUE_WIDTH-1:0] cand_take
);
endmodule
```

### 13.10 `issue_sched`

```systemverilog
module issue_sched #(
    parameter integer ISSUE_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer LQ_DEPTH = 8,
    parameter integer SQ_DEPTH = 8,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1,
    parameter integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1,
    parameter integer MIDW = (LIDW > SIDW) ? LIDW : SIDW,
    parameter integer ALU_IQ_BITS = RW + 6 + PW + PW + PW + 32 + 32,
    parameter integer MEM_IQ_BITS = RW + 3 + MIDW + PW + PW + 32,
    parameter integer ALU_EXEC_BITS = RW + 6 + PW + 32 + 32 + 32 + 32,
    parameter integer MUL_EXEC_BITS = RW + 3 + PW + 32 + 32,
    parameter integer MEM_EXEC_BITS = 3 + MIDW + 32 + 32 + 32
) (
    input logic clock,
    input logic reset,
    input logic kill,
    input logic [RW-1:0] rob_head,
    input logic [ISSUE_WIDTH-1:0] alu_cand_valid,
    input logic [ISSUE_WIDTH*ALU_IQ_BITS-1:0] alu_cand_uop, // alu_iq_t
    output logic [ISSUE_WIDTH-1:0] alu_cand_take,
    input logic [ISSUE_WIDTH-1:0] mem_cand_valid,
    input logic [ISSUE_WIDTH*MEM_IQ_BITS-1:0] mem_cand_uop, // mem_iq_t
    output logic [ISSUE_WIDTH-1:0] mem_cand_take,
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
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer ALU_EXEC_BITS = RW + 6 + PW + 32 + 32 + 32 + 32,
    parameter integer ALU_RESULT_BITS = RW + PW + 32 + 32
) (
    input logic clock,
    input logic reset,
    input logic kill,
    input logic exec_valid,
    output logic exec_ready,
    input logic [ALU_EXEC_BITS-1:0] exec_payload, // alu_exec_t
    output logic result_valid,
    input logic result_ready,
    output logic [ALU_RESULT_BITS-1:0] result_payload // alu_result_t
);
endmodule
```

### 13.12 `mul_div`

```systemverilog
module mul_div #(
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer MUL_EXEC_BITS = RW + 3 + PW + 32 + 32,
    parameter integer RESULT_BITS = RW + PW + 32
) (
    input logic clock,
    input logic reset,
    input logic kill,
    input logic exec_valid,
    output logic exec_ready,
    input logic [MUL_EXEC_BITS-1:0] exec_payload, // mul_exec_t
    output logic result_valid,
    input logic result_ready,
    output logic [RESULT_BITS-1:0] result_payload // result_t
);
endmodule
```

### 13.13 `wb_arb`

```systemverilog
module wb_arb #(
    parameter integer ISSUE_WIDTH = 2,
    parameter integer WB_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer ALU_RESULT_BITS = RW + PW + 32 + 32,
    parameter integer RESULT_BITS = RW + PW + 32,
    parameter integer ROB_DONE_BITS = RW + 32
) (
    input logic clock,
    input logic reset,
    input logic kill,
    input logic [ISSUE_WIDTH-1:0] alu_result_valid,
    output logic [ISSUE_WIDTH-1:0] alu_result_ready,
    input logic [ISSUE_WIDTH*ALU_RESULT_BITS-1:0] alu_result_payload, // alu_result_t
    input logic mul_result_valid,
    output logic mul_result_ready,
    input logic [RESULT_BITS-1:0] mul_result_payload, // result_t
    input logic lsu_result_valid,
    output logic lsu_result_ready,
    input logic [RESULT_BITS-1:0] lsu_result_payload, // result_t
    output logic [WB_WIDTH-1:0] done_valid,
    output logic [WB_WIDTH*ROB_DONE_BITS-1:0] done_payload, // rob_done_t
    output logic [WB_WIDTH-1:0] write_valid,
    output logic [WB_WIDTH*PW-1:0] write_pdst,
    output logic [WB_WIDTH*32-1:0] write_value
);
endmodule
```

### 13.14 `lsu`

```systemverilog
module lsu #(
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer LQ_DEPTH = 8,
    parameter integer SQ_DEPTH = 8,
    parameter integer LOAD_OUTSTANDING = 8,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1,
    parameter integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1,
    parameter integer MIDW = (LIDW > SIDW) ? LIDW : SIDW,
    parameter integer LQ_CW = $clog2(LQ_DEPTH + 1),
    parameter integer SQ_CW = $clog2(SQ_DEPTH + 1),
    parameter integer MEM_ALLOC_BITS = 1 + MIDW + RW + PW,
    parameter integer MEM_EXEC_BITS = 3 + MIDW + 32 + 32 + 32,
    parameter integer RESULT_BITS = RW + PW + 32,
    parameter integer LD_REQ_BITS = LIDW + 32,
    parameter integer LD_RSP_BITS = LIDW + 32,
    parameter integer WRITE_REQ_BITS = 32 + 32 + 4
) (
    input logic clock,
    input logic reset,
    input logic kill,
    input logic [RW-1:0] rob_head,
    input logic [DISPATCH_WIDTH-1:0] disp_valid,
    input logic [DISPATCH_WIDTH*MEM_ALLOC_BITS-1:0] disp_lsq, // mem_alloc_t × D
    output logic [LQ_CW-1:0] lq_free,
    output logic [SQ_CW-1:0] sq_free,
    output logic [DISPATCH_WIDTH*LIDW-1:0] lq_alloc_id,
    output logic [DISPATCH_WIDTH*SIDW-1:0] sq_alloc_id,
    input logic exec_valid,
    output logic exec_ready,
    input logic [MEM_EXEC_BITS-1:0] exec_payload, // mem_exec_t
    output logic result_valid,
    input logic result_ready,
    output logic [RESULT_BITS-1:0] result_payload, // result_t
    input logic st_start_valid,
    input logic [SIDW-1:0] st_start_id,
    output logic st_done_valid,
    output logic ld_req_valid,
    input logic ld_req_ready,
    output logic [LD_REQ_BITS-1:0] ld_req_payload, // ld_req_t
    input logic ld_rsp_valid,
    input logic [LD_RSP_BITS-1:0] ld_rsp_payload, // ld_rsp_t
    output logic st_req_valid,
    input logic st_req_ready,
    output logic [WRITE_REQ_BITS-1:0] st_req_payload, // write_req_t
    input logic st_rsp_valid
);
endmodule
```

### 13.15 `axi_bridge`

```systemverilog
module axi_bridge #(
    parameter integer LQ_DEPTH = 8,
    parameter integer FETCH_QUEUE_DEPTH = 16,
    parameter integer AXI_RD_OUTSTANDING = 16,
    parameter integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1,
    parameter integer FIDW = (FETCH_QUEUE_DEPTH > 1) ? $clog2(FETCH_QUEUE_DEPTH) : 1,
    parameter integer IF_REQ_BITS = FIDW + 32,
    parameter integer IF_RSP_BITS = FIDW + 32,
    parameter integer LD_REQ_BITS = LIDW + 32,
    parameter integer LD_RSP_BITS = LIDW + 32,
    parameter integer WRITE_REQ_BITS = 32 + 32 + 4
) (
    input logic clock,
    input logic reset,
    input logic run,
    output logic idle,
    input logic if_req_valid,
    output logic if_req_ready,
    input logic [IF_REQ_BITS-1:0] if_req_payload, // if_req_t
    output logic if_rsp_valid,
    output logic [IF_RSP_BITS-1:0] if_rsp_payload, // if_rsp_t
    input logic ld_req_valid,
    output logic ld_req_ready,
    input logic [LD_REQ_BITS-1:0] ld_req_payload, // ld_req_t
    output logic ld_rsp_valid,
    output logic [LD_RSP_BITS-1:0] ld_rsp_payload, // ld_rsp_t
    input logic st_req_valid,
    output logic st_req_ready,
    input logic [WRITE_REQ_BITS-1:0] st_req_payload, // write_req_t
    output logic st_rsp_valid,
    output logic [32-1:0] araddr,
    output logic arvalid,
    input logic arready,
    input logic [32-1:0] rdata,
    input logic [2-1:0] rresp,
    input logic rvalid,
    output logic rready,
    output logic [32-1:0] awaddr,
    output logic awvalid,
    input logic awready,
    output logic [32-1:0] wdata,
    output logic [4-1:0] wstrb,
    output logic wvalid,
    input logic wready,
    input logic [2-1:0] bresp,
    input logic bvalid,
    output logic bready
);
endmodule
```

## 14. 顶层连接

- Fetch 的 fetch_* 接 Decode，Decode 的 decode_* 接 Rename；Fetch 的 if_req/if_rsp 接桥。请求有 ready，读响应为事件。
- Rename 的各派遣投影分别接 ROB、两 IQ 和 LSU；顶层仅根据 disp_rob.kind 生成两个 IQ/LSU 的有效 lane，并按第 6 节产生统一 fire。ROB 的 rob_tail/rob_free、IQ 容量和 LSU 候选列表返回 Rename。
- rob_head 只送两 IQ、issue_sched 和 LSU，用于活跃项年龄比较。ROB 不输出 D 份连续标签，IQ 不输出内部候选槽编号。
- IQ cand_uop/cand_valid 接 issue_sched，cand_take 返回 IQ；issue_sched 的 rd_addr 接 PRF，rd_data 返回。alu_exec 的 lane k 接 ALU[k]，mul_exec 接 MULDIV，mem_exec 接 LSU。
- ALU[k] 的 result 接 wb_arb 的 alu_result lane k；MULDIV 和 LSU 接各自 result 端口，ready 原路返回。wb_arb.done_* 只接 ROB；write_* 接 PRF，write_valid/write_pdst 另接 Rename 和两 IQ 的 wake_*，不广播 value 或 npc。
- ROB 的 reg_commit_* 只接 Rename；st_start_* 接 LSU，st_done_valid 返回 ROB。LSU 不接退休总线；Load 在结果接收时回收 LQ，Store 在 B 完成事件时回收 SQ。
- LSU 的 ld_req/ld_rsp、st_req/st_rsp 接桥；写请求和完成不携带 ID。桥外部 AXI 接 student_top 同名端口，rresp/bresp 只接桥的兼容端口。
- ROB 的 recover_valid/recover_pc 接 branch_ctrl，桥的 idle 接 bridge_idle；控制器按第 12 节定向连接 run/kill/restore/restart_pc。PRF 不接 kill，写使能来自已被 kill 门控的 write_valid。
