# RV32IM 指令缓存乱序核接口规范

版本：v1.6.0。本文定义成员 A、B 的实现接口；与 `plan.md` 冲突时以本文为准。外部接口遵守 [README](README-ZH.md) 和 [AXI 规范](docs/axi4-lite.md)。

## 1. 架构与实现边界

- RV32IM、乱序发射、按序提交、物理寄存器重命名；带 Instruction Cache；无 Data Cache、Store 转发、投机访存消歧或预测表；使用分支 checkpoint 和 16-bit generation。
- 默认预测下一 PC 为 PC+4；一个取指包内按 PC+4 连续递增。分支执行产生真实下一 PC 时纠正误预测，不等待退休或 WB 仲裁。
- 正确路径指令受支持且访问合法；所有路径地址按访问宽度自然对齐。正确路径取指、Load 访问 RAM，Store 访问 RAM 或执行合法退出写。运行期间指令内存保持不变，不支持自修改代码或 Store 引起的 ICache 失效。无 CSR、特权陷入或精确异常状态。
- Store 仅在 ROB 头部获得外部写授权。RAM Load 可越过地址已知且字节范围不重叠的旧 Store；非 RAM Load 在本地返回零。
- 分支误预测只 squash 更年轻状态，保留该分支及更老工作；Fetch 立即切换 PC，Rename 从分支 checkpoint 恢复。桥继续完成旧事务，并在剩余容量内接收新路径请求。
- 接口只携带接收方消费的字段，不提供调试、退休轨迹、断言、额外诊断性一致性检查、超时、重试或配置检查电路。不要求验证基础设施。

ICache 命中时每拍最多取得 D 个 32 位指令字；每包不跨 Cache line。缺失采用单行填充，允许填充期间其他有效行命中；逐字填充与数据读取共享总线。错误路径可以占用内部资源和读取 RAM，但不能改变已提交寄存器、内存或外设状态，不能触发退出。队列满时背压；除第 12 节明确的 generation 不回绕假设外，正确性不依赖错误路径长度或误预测次数的上限。未知编码转 NOP、非 RAM 读门控、身份匹配、generation 匹配、Store 授权和 squash 是这一功能要求的一部分。

| 模块 | 主责 | 职责 |
|---|---|---|
| student_top / fetch / icache / decode | A | 接线、多指令取指、指令缓存、译码 |
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
| WB_WIDTH（W） | 1 | 1/2/4，每拍接受完成数 |
| COMMIT_WIDTH（C） | 1 | 1/2/4 |
| ROB_DEPTH（R） | 32 | 2 的幂，至少 8，且不小于 I/D/W/C |
| PRF_SIZE（P） | 64 | 至少 32+D |
| IQ_ALU_DEPTH / IQ_MEM_DEPTH | 16 / 16 | 2 的幂，至少 D |
| LQ_DEPTH / SQ_DEPTH | 8 / 8 | 2 的幂，至少 D |
| FETCH_QUEUE_DEPTH（F） | 16 | 2 的幂，至少 D |
| IFETCH_OUTSTANDING | 8 | 1–16，不大于 F；当前路径已被 ICache 接受且未返回的指令槽数 |
| ICACHE_SIZE_BYTES | 4096 | 2 的幂，至少 ICACHE_WAYS × ICACHE_LINE_BYTES |
| ICACHE_WAYS | 2 | 1/2/4 |
| ICACHE_LINE_BYTES | 32 | 16/32/64 字节 |
| LOAD_OUTSTANDING | 8 | 1–16，不大于 LQ_DEPTH |
| AXI_RD_OUTSTANDING | 16 | 1–16，IF/LD 共享 |
| CHECKPOINT_DEPTH（K） | 4 | 1..R，控制流派遣前分配 |
| GEN_WIDTH | 16 | generation 位宽；在任何旧读事务存活期间不回绕碰撞 |
| RESET_PC | 32'h00000000 | RAM 内，4 字节对齐 |

XLEN 固定 32，不作为参数。最多一笔未完成写。参数满足上表是集成前提，不增加参数合法性检查。

Cache 组数 `S=ICACHE_SIZE_BYTES/(ICACHE_WAYS*ICACHE_LINE_BYTES)` 为 2 的幂，允许 S=1；行字数 `L=ICACHE_LINE_BYTES/4`。`IF_ID_WIDTH=IDX(L)` 用于填充字编号，`DCW=CNT(D)` 用于包 count。

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
| `branch_resolve_t` | `rob:rob_tag_t, cp_id:CIDW, npc:32` |
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

下表位数沿用 D=I=W=C=2 的配置示例；顶层当前默认宽度为 1。

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
| `RESOLVE_BITS` | TAG_BITS + CIDW + 32 | 39 |
| `CP_ALLOC_BITS` | CIDW + TAG_BITS + 32 | 39 |
| `FETCH_REDIRECT_BITS` | 32 + GEN_WIDTH | 48 |
| `REG_COMMIT_BITS` | PW | 6 |
| `IC_REQ_BITS` | GEN_WIDTH + FIDW + DCW + 32 | 54 |
| `IC_RSP_BITS` | GEN_WIDTH + FIDW + DCW + 32×D | 86 |
| `IF_REQ_BITS` | GEN_WIDTH + IF_ID_WIDTH + 32 | 51 |
| `IF_RSP_BITS` | GEN_WIDTH + IF_ID_WIDTH + 32 | 51 |
| `LD_REQ_BITS` | GEN_WIDTH + LIDW + 32 | 51 |
| `LD_RSP_BITS` | GEN_WIDTH + LIDW + 32 | 51 |
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

Fetch 每拍预留至多 D 个槽，每槽保存 pc/pred_npc/generation；pred_npc=pc+4。包内 PC 按模 2^32 连续递增，每包不跨 Cache line；队列空闲空间、行尾剩余字数或取指额度不足时取更短前缀。已有 offer 被背压时不再创建新 offer 或重复推进 PC。可在旧 offer 接受同拍建立下一包。就绪指令复制进输出缓冲时即释放源槽并推进队首，释放槽在下一拍参与分配；F 统计队列槽容量，输出缓冲另容纳一个至多 D 条的包。

RAM 内槽形成 ic_req 保持型请求，id 为首槽编号，count 为 1..D；lane k 的槽号为 (id+k) mod F。接受请求后按 count 增加 outstanding；ICache 为每个已接受包产生一次 ic_rsp 事件，含相同 gen/id/count 和按 lane 排列的指令字。Fetch 只消费当前 fetch_gen 的响应，每槽还必须处于 waiting 且 slot_gen 匹配，才写入 inst 并置 ready。当前路径响应按 count 归还额度；旧 generation 的包不写槽也不改变当前路径额度。RAM 外 PC 本地填 inst=0 并就绪，不占取指额度、不进入 ICache。

fetch_redirect 当拍取消未接受 offer 和旧输出，边沿清旧槽及当前路径 outstanding，设置目标 PC，并将 fetch_gen 更新为 payload.new_gen。generation 只由 branch_ctrl 产生。ICache 同拍取消旧等待包与旧命中响应，不再为取消的包返回事件；物理填充读数由 ICache/桥独立维护，不受 Fetch 清零影响。下一拍可创建新路径槽。复位 PC=RESET_PC、fetch_gen=0。

最老连续就绪的至多 D 个槽形成 fetch_packet，valid 时 count 为 1..D，整包接受。输出缓冲可在旧包接受的边沿装入后续就绪包，无输出空拍；复制后不再引用源槽，背压期间 count 和载荷保持。Decode 纯组合转换，count 原样传递；Rename 缓冲已接收的包。

### 5.2 Instruction Cache

Cache 默认 4 KiB、2 路、32 B 行、64 组。完整 32 位地址拆成 tag、组号、行内字号。每路一个同步 1RW sram_fakeram，DEPTH=S、WIDTH=ICACHE_LINE_BYTES×8，整行写入；tag、valid 与每组替换指针用寄存器。复位只清 valid、替换指针及控制状态，不清 tag、SRAM 或无效载荷。

命中请求在接受边沿启动 SRAM 读，下一周期产生包响应；无写入冲突时可每拍接收一个包。替换先选最低编号无效路，否则选轮转指针；分配填充时立即使目标路无效，安装成功后将指针推进到该路的下一路。

唯一 MSHR 保存行地址、目标组/路、填充 generation、发送/返回计数、整行缓冲和一个可取消等待包。行按字号 0..L-1 逐字发 if_req，id 为行内字号，addr=line_base+4×id，每拍最多一笔，可多笔在途。桥响应按原 gen/id 写整行缓冲；填充读不占 IFETCH_OUTSTANDING。收齐后一个周期写整行 SRAM 并发布 tag/valid，等待包随后从填充缓冲返回；不做关键字优先或提前返回。

填充期间其他有效行可以命中。填充写入周期背压全部新包；第二个不同行 miss 等待 MSHR 释放。同一填充行在没有有效等待包时，可接收一个新等待包。每拍最多一个 ic_rsp，命中读取优先，填充完成包缓存在 MSHR 中直到能发送；安装且等待包已发送或取消后释放 MSHR。

fetch_redirect 当拍禁止取指包接收与响应，清命中响应状态及等待包，但保留有效缓存和物理填充，并继续发送、接收整行读事务。新路径命中可继续；同一填充行可重新建立等待包，不同行 miss 须等待。等待包 generation 与填充 generation 分别锁存，旧填充可向新 generation 的有效等待包供数。

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
| branch_ctrl | cp_free、cp_alloc_id[D] | checkpoint 空闲数及最低编号候选 |

ROB 不输出可由尾索引推导的 D 份标签。LQ/SQ 完成顺序可以不同于分配顺序，保留空闲位图和候选槽列表。

### 6.2 派遣投影

Rename 保留一个译码包缓冲和一个派遣 offer。根据全部容量选取最大可容纳前缀，锁存 count、ROB 索引、物理目的、访存槽及 checkpoint 候选；未选后缀留在译码缓冲。每个控制流指令消耗一个 checkpoint。offer 只在 disp_valid&&disp_ready 时原子生效，背压期间内容不变。

| 投影 | 接收方 | 数据 |
|---|---|---|
| disp_rob[D] | ROB | rob_alloc_t |
| disp_alu[D] | ALU IQ | alu_iq_t，仅非访存 lane 有意义 |
| disp_mem[D] | MEM IQ | mem_iq_t，仅访存 lane 有意义 |
| disp_lsq[D] | LSU | mem_alloc_t，仅访存 lane 有意义 |
| disp_src1_ready/disp_src2_ready[D] | 两个 IQ | 源就绪侧带，在对应派遣事件采样 |
| cp_alloc_valid[D]、cp_alloc_payload[D] | branch_ctrl | 控制流 lane 的 cp_alloc_t 分配事件；Rename 同拍保存快照 |
| front_redirect_valid/front_redirect_pc | branch_ctrl | 非控制流错误预测的前端纠正事件，仅给出真实下一 PC |

顶层根据 disp_rob.kind 统计 need_alu/need_mem/need_lq/need_sq；统一 fire 为 `disp_valid && disp_ready`，disp_ready 由 !squash_valid 及四类队列和 ROB 的容量满足条件产生。Checkpoint 候选已在形成 offer 时锁定；除了这个 offer 没有其他新资源申请者，分支恢复只消费既有预留编号并取消旧 offer，故背压期间候选不会被抢走。ROB 接收 disp_fire、disp_count 和 disp_rob；IQ 接收按类别与 fire 生成的逐 lane disp_valid；LSU 接收同样的访存 lane 事件。无效 lane 载荷不消费，不为 LSU 或 IQ 传递全核 count 和其他模块的投影。

Rename 按包内顺序读取临时推测 RAT 的源映射；对非零 rd，先把更新前映射记录为该 lane 的 `old_pdst`，再分配最低编号空闲 pdst 并更新临时 RAT；无目的写 lane 的 `old_pdst=0`。后续 lane 读取更新后的映射。ps1/ps2=0 时源总是就绪。只有 fire 才更新推测 RAT、空闲表和分配状态。offer 中编号保持，源就绪侧带读取实时 ready 表并合入当拍唤醒；若源来自同包较老 lane 的新目的则未就绪。

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

IQ 仅接收自己的派遣投影及 `wake_valid[W]/wake_pdst[W]`，不接收结果数据、ROB 完成信息、控制流目标或退休信息。各 IQ 存储本地有效位与源就绪位，每拍给出至多 I 个按 ROB 年龄排序的就绪候选。Rename 的物理 ready 表在派遣时清新目的位，在 wake_valid 时置对应目的位；IQ 在派遣时采样源就绪，随后按源物理编号匹配唤醒。

候选接口为 cand_valid[I]、cand_uop[I]、cand_take[I]。ALU IQ 在候选选择后有 I 个 candidate_reg 队列项，MEM IQ 有一个 candidate_reg 队列项，每项保存一条指令；就绪指令在 IQ entry→candidate_reg 的上升沿正式离开 IQ 并释放原槽，下一拍才对 issue_sched 可见。alu_iq_free 和 mem_iq_free 只统计各自 IQ 内部空槽，不包含 candidate_reg；cand_take 在上升沿消费对应 candidate_reg 项，同拍可从 IQ 补入新项。ALU candidate_reg 输出按 ROB 年龄排序，MEM 每次搬入 ROB 年龄最老的就绪项；同龄时 IQ 槽号较小者先选，每个发射 lane 排除先前 lane 已选的槽。背压时保留未消费项。squash 当拍屏蔽年轻候选并在边沿移除，只允许存活指令补入。同一指令在候选接口只出现一次。选择逻辑支持非 2 的幂的 IQ 深度和正整数发射宽度。

issue_sched 合并两组候选，按 ROB 年龄选择可容纳的最老项，同龄时按 ALU 候选槽号升序、再按 MEM 候选的顺序选择；后续发射 lane 排除先前 lane 已选的候选和已占用的执行入口。每拍总 take 数不超过 I。它保留 I 个 ALU 入口、一个 MULDIV 入口、一个 AGU 入口，各深度 1；周期开始时为空的入口可接收新项。ALU IQ 的 op=38..45 投影到 mul_exec_t，其他项投影到 alu_exec_t；MEM IQ 投影到 mem_exec_t。

PRF 有 2I 个组合读口，选择序号 k 使用读口 2k/2k+1，操作数与执行投影一起在 take 边沿锁存。每个读口按连续 8 项分 bank：地址低 3 位在各 bank 内译码选择数据，高位译码选择 bank；最后一个 bank 可不足 8 项。PRF 有 W 个写口，write_valid/pdst/value 只驱动对应写入。p0 读零，不写入；读口只读取已存储值，不做同拍写入旁路，写值在接收边沿后可读。两个 IQ 的已有项均可在收到当拍唤醒的边沿直接搬入 candidate_reg，下一拍才成为对外候选，此时 PRF 写入已完成。派遣与唤醒同拍时仍记录该唤醒，新项最早下一拍才参与候选选择。

PRF 复位只需将 p1..p31 的初始架构值设零；p0 可直接用常量实现，其他数据不复位。checkpoint 恢复只处理被 squash 的目的和映射，不清 PRF 数据。

## 8. 执行与定向完成

### 8.1 执行单元

ALU 使用一项结果缓冲，接收请求后最早下一拍 result_valid；满时背压。ALU 根据 op 使用寄存器值、PC 或 imm，计算 32 位结果。NOP 正常产生一次完成，pdst=0。

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

每个 ALU 在控制流结果首次产生时输出一次 `resolve_valid/resolve_payload:branch_resolve_t`，携带 tag、cp_id 和真实 npc；结果缓冲保留一次性解析待发位。事件不等待 result_ready，下一拍清除解析待发位，即使普通结果继续背压也不重复解析。候选取自已锁存的执行结果/有效位，不组合依赖本次 squash 或 WB ready。

branch_ctrl 同时接收 I 条解析事件，以有效 checkpoint 的 cp_id/tag 匹配并比较 pred_npc。在多条误预测中选择按恢复前 rob_head 计算的最老者；该分支及更老解析均生效，更年轻解析被 squash。匹配正确的存活分支只释放 checkpoint。

IQ、发射入口、ALU/MULDIV、AGU、LSU 完成缓冲按第 12 节取消年轻项；较老运算及触发分支本身不被清空。长延迟乘除只有其身份比恢复边界年轻时才终止。解析不等于写回或退休：JAL/JALR 的结果可在恢复之后才写 PRF。

### 8.2 完成仲裁与消费者

wb_arb 接收 I 路 ALU、一条乘除和一条 LSU 结果，统一使用 result_t，不携带控制流目标。源编号 0..I-1 为 ALU、I 为 MULDIV、I+1 为 LSU。WB 直接接收 squash_valid/tag 和 rob_head，仲裁前按周期开始时的 head 屏蔽本拍 squash 的年轻结果，不向 ROB 发起存活查询。

此筛选依赖第 2 节既有的内部生命周期约定：每条指令只产生一次被接收的完成，接收后源清除该结果；被 squash 的内部工作在该边沿取消，之后不能重现旧结果。LSU 先按 LQ 完整身份过滤外部迟到响应，再产生结果。因此待仲裁结果均属于周期开始时活跃的 ROB 项，只需处理本拍 squash 的年龄边界。

只在 result_valid 且未被本拍 squash 时参加 W 路轮询仲裁，每源每拍至多一个；指针移至最后接收源之后，没有存活接收则保持。被 squash 的有效结果直接 ready 接收并丢弃，不占 WB lane。被取消的 FU 也可直接撤销其年轻结果 valid。

| 输出 | 接收方 | 内容 |
|---|---|---|
| done_valid[W]、done_tag[W] | ROB | 仅 rob_tag_t |
| write_valid[W]、write_pdst[W]、write_value[W] | PRF | 存活完成且 pdst!=0 时写入 |
| write_valid[W]、write_pdst[W] 的分支线 | Rename、两 IQ 的 wake 端口 | 仅物理目的和有效位，不增加结果数据 |

完成、PRF 写与唤醒在同一接收边沿发生。NOP、无链接分支或 Store 仍使用完成 lane，pdst=0 不影响 done。WB 不因发生恢复而整体关闭；触发分支及更老结果仍可当拍写入，更年轻结果不能产生完成或唤醒。

## 9. ROB 与退休

ROB 每项保存 `rob_alloc_t`（其中含 old_pdst/kind/sq_id）、done 和 Store 授权/响应状态，不保存原指令、PC、预测值、实际目标、mispred 或 checkpoint 副本。头尾索引仍为 RW 位。ROB 不输出 generation 占用向量。

非 Store 指令（含控制流、Load）每拍退休至多 C 条连续已完成前缀；遇到未完成项或 Store 停止，较老前缀先退休。控制流与其他非 Store 指令共用退休宽度，不截断前缀，也不再触发恢复；实际目标的解析事件在其首次结果可见时已处理。Store 仍在头部单独授权、等待写完成后单独退休。当拍完成最早下一拍退休；squash 当拍的退休前缀不得包含边界之后的年轻项。

Store 在头部且执行完成后产生一次 st_start_valid/st_start_id 事件。LSU 的 SQ 已预留且上一个授权 Store 已完成，故无需 ready 或往返 ROB ID。收到 st_done_valid 后 ROB 记已响应，最早下一拍退休。更年轻分支解析时，头部 Store 可能正在等待 AW/W/B，这项授权和等待状态必须保留。

ROB 只向 Rename 发出写寄存器退休 lane 的 reg_commit_valid/old_pdst，允许空洞；`old_pdst!=0` 即表示该项存在架构寄存器写。退休时 Rename 直接释放 old_pdst；LSU 不接退休广播。

squash 边界 b 来自尚未退休的解析分支。按周期开始时 head 计算 keep_count=age(b)+1，令 tail=(b.index+1) mod R，清除其后年轻项。更老同拍退休 m 项仍生效：head 正常前移，count=keep_count-m；触发分支尚未在本拍完成状态中退休，不提前释放。所有有效的较老 done/Store 完成继续更新保留项。squash 当拍不接新派遣。ROB 不向 branch_ctrl 发退休恢复事件。

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

RAM Load 扫描更老 SQ：旧 Store 地址未知或同字节重叠且未完成写时等待；地址不同或字节掩码不相交可发送。LSU 从 branch_ctrl 接收 `current_gen`；形成新的 ld_req offer 时把当时的 `current_gen` 锁存在该 LQ 槽中。ld_req 为保持型通道，携带 `{gen,id}`，桥接收后计入读额度；ld_rsp 是无 ready 事件，每次事件均减少读额度。只有该 id 的 LQ 仍等待响应、`{gen,id}` 与该槽记录匹配且其 tag 不属于本拍 squash 范围时才存入数据；不匹配的响应只归还额度并丢弃。WB 背压不会占用桥内响应缓冲。

非 RAM Load 不发请求，在其 LQ 产生零值并标记数据就绪，不占读额度，不等待 Store 消歧或外部响应。这使任意错误路径 Load 不访问 MMIO，也不会等待不存在的结果。

LSU 只有一个 result_t 输出缓冲，仅在周期开始时为空时填入；从数据就绪的 LQ 和地址/数据就绪的 SQ 中选最老且完成未发送的项；载荷从队列记录取 tag/pdst，Store 的 pdst=0。完成被 wb_arb 接收后，Load 立即释放 LQ；Store 标记执行完成已发送并继续保留 SQ。LQ 不必等退休，已返回的读事务不存在迟到响应。

SQ 接收头部 st_start_id 后建立仅含 addr/data/strb 的 st_req；同一时刻只有一个授权 Store。桥发出 st_rsp_valid 时，LSU 同拍向 ROB 发出 st_done_valid，并在边沿释放对应 SQ。Store 已完成外部写后即可解除所有相关 Load 依赖，不必等待下一拍 ROB 退休；等待 AW/W 接受不能代替等待 B。

错误路径 Store 不会取得头部授权，任意地址仅保留在 SQ。正确路径合法退出 SW 也遵守相同授权及 AW/W/B 协议。LSU 不检查授权地址或标签的一致性，不为冗余核对传递副本。

squash 只清除年轻 LQ/SQ、年轻未接受请求和年轻完成缓冲，保留较老队列、消歧依赖和授权写状态。桥已接受的年轻读继续返回，LQ 槽可在下一拍复用（发出新请求时锁存新 generation）；LOAD_OUTSTANDING 计数不清零，旧读返回时照常归还额度。较老 Store 和它阻塞的较老 Load 关系保留；已移除的年轻 Store 不再参与消歧。

恢复当拍同时处理 R/B 事件：`{gen,id}` 不匹配的 R 只归还额度，匹配的 R 更新其 LQ；较老授权 Store 的 B 正常产生 st_done 并释放 SQ。不能因 generation 已切换而丢弃写完成。

## 11. AXI 桥

### 11.1 读通路

ICache 填充 IF/LD 请求为独立保持型通道，分别使用 IF_ID_WIDTH/LIDW 位 id，并携带请求所属 generation（`{gen,id}`）；外部 AXI 端口不增加 ID。共享最多 AXI_RD_OUTSTANDING 笔请求；两者同时有效时轮询，复位 IF 优先，每次接收后优先另一方，每拍至多接受一个。桥本地记录 source、generation、对应槽号和 AR 所需地址。LD 的 generation 来自原 Load 发出时锁存的值，不强制改成当前 generation。

已接受请求按顺序发送 AR，arvalid/addr 保持至 arready。请求描述符保留到对应 R 握手；AXI 无 ID，R 匹配最老的已发 AR 请求。同拍刚握手的 AR 最早下一拍才接受其 R，符合外部从机延迟约定。

ICache 填充缓冲和 LSU 为每个读预留了接收槽，因此不提供 if_rsp_ready/ld_rsp_ready，也不需要桥内返回数据队列。存在已发 AR 的队首事务时桥接收 R，在握手拍向对应客户端发送一次 `{gen,id,data}` 事件并释放桥槽。无论身份是否已被 squash 都返回事件，由客户端按 `{gen,id}` 匹配：ICache 按物理填充身份写整行缓冲，LSU 匹配则写槽，否则丢弃数据并归还 Load 额度。桥不按当前 generation 过滤，也不因前端恢复而阻塞 R。

### 11.2 写通路

桥只有一个写槽，st_req 为 addr/data/strb 保持型通道，不携带事务 ID。接受后分别维护 aw_pending、w_pending；AW 与 W 独立驱动并各自保持至握手。两者完成后接收 B，`st_rsp_valid=bvalid&&bready` 为无载荷完成事件，LSU 无需 ready；桥在该边沿释放写槽。不保存 bresp 或额外写响应缓冲。

### 11.3 跨 generation 的事务履约

桥不接收 run/kill/restore/squash，也不提供恢复用 idle。即使请求所属路径已经失效，已接受请求仍按原顺序完成 AR/R 或 AW/W/B；已展示的 VALID 保持到握手。新路径可使用剩余容量，不需要等整个桥排空；总线队列满仍会产生正常背压。

写请求不增加 generation 字段：它只来自不可 squash 的已授权 Store，其 ROB 项会一直保留到写完成后退休。

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
    parameter integer WB_WIDTH = 1,
    parameter integer COMMIT_WIDTH = 1,

    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer IQ_ALU_DEPTH = 16,
    parameter integer IQ_MEM_DEPTH = 16,
    parameter integer LQ_DEPTH = 8,
    parameter integer SQ_DEPTH = 8,
    parameter integer FETCH_QUEUE_DEPTH = 16,
    parameter integer IFETCH_OUTSTANDING = 8,
    parameter integer ICACHE_SIZE_BYTES = 4096,
    parameter integer ICACHE_WAYS = 2,
    parameter integer ICACHE_LINE_BYTES = 32,
    parameter integer LOAD_OUTSTANDING = 8,
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
endmodule
```

### 13.2 `fetch`

```systemverilog
module fetch #(
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
    parameter integer DECODE_BITS = 32 + 32 + 6 + 5 + 5 + 5 + 32,
    parameter integer ROB_ALLOC_BITS = PW + 2 + SIDW,
    parameter integer ALU_IQ_BITS = TAG_BITS + CIDW + 6 + PW + PW + PW + 32 + 32,
    parameter integer MEM_IQ_BITS = TAG_BITS + 3 + MIDW + PW + PW + 32,
    parameter integer MEM_ALLOC_BITS = 1 + MIDW + TAG_BITS + PW,
    parameter integer CP_ALLOC_BITS = CIDW + TAG_BITS + 32,
    parameter integer REG_COMMIT_BITS = PW
) (
    input logic clock,
    input logic reset,
    input logic squash_valid,
    input logic [CIDW-1:0] restore_cp_id,
    input logic [CHECKPOINT_DEPTH-1:0] cp_release_mask,
    input logic [CCW-1:0] cp_free,
    input logic [DISPATCH_WIDTH*CIDW-1:0] cp_alloc_id,
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
    output logic [DISPATCH_WIDTH-1:0] cp_alloc_valid,
    output logic [DISPATCH_WIDTH*CP_ALLOC_BITS-1:0] cp_alloc_payload, // cp_alloc_t
    output logic front_redirect_valid,
    output logic [31:0] front_redirect_pc,
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
    parameter integer TAG_BITS = RW,
    parameter integer ROB_ALLOC_BITS = PW + 2 + SIDW,
    parameter integer REG_COMMIT_BITS = PW
) (
    input logic clock,
    input logic reset,
    input logic squash_valid,
    input logic [TAG_BITS-1:0] squash_tag, // rob_tag_t
    input logic disp_fire,
    input logic [DCW-1:0] disp_count,
    input logic [DISPATCH_WIDTH*ROB_ALLOC_BITS-1:0] disp_rob, // rob_alloc_t × D
    input logic [WB_WIDTH-1:0] done_valid,
    input logic [WB_WIDTH*TAG_BITS-1:0] done_tag, // rob_tag_t × W
    output logic [ROB_CW-1:0] rob_free,
    output logic [RW-1:0] rob_tail,
    output logic [RW-1:0] rob_head,
    output logic [COMMIT_WIDTH-1:0] reg_commit_valid,
    output logic [COMMIT_WIDTH*REG_COMMIT_BITS-1:0] reg_commit_payload, // reg_commit_t
    output logic st_start_valid,
    output logic [SIDW-1:0] st_start_id,
    input logic st_done_valid
);
endmodule
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
    parameter integer RESOLVE_BITS = TAG_BITS + CIDW + 32,
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

`cand_valid/cand_uop` 来自每 lane 一个 candidate_reg 队列项；从 IQ 搬入时释放 IQ 槽，`cand_take` 消费寄存项，并允许同拍补位。端口和 `alu_iq_t` 布局不变。

```systemverilog
module iq_alu #(
    parameter integer ISSUE_WIDTH = 2,
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer WB_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer IQ_ALU_DEPTH = 16,
    parameter integer CHECKPOINT_DEPTH = 4,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer CIDW = (CHECKPOINT_DEPTH > 1) ? $clog2(CHECKPOINT_DEPTH) : 1,
    parameter integer AIQ_CW = $clog2(IQ_ALU_DEPTH + 1),
    parameter integer TAG_BITS = RW,
    parameter integer ALU_IQ_BITS = TAG_BITS + CIDW + 6 + PW + PW + PW + 32 + 32
) (
    input logic clock,
    input logic reset,
    input logic squash_valid,
    input logic [TAG_BITS-1:0] squash_tag, // rob_tag_t
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
    parameter integer TAG_BITS = RW,
    parameter integer MEM_IQ_BITS = TAG_BITS + 3 + MIDW + PW + PW + 32
) (
    input logic clock,
    input logic reset,
    input logic squash_valid,
    input logic [TAG_BITS-1:0] squash_tag, // rob_tag_t
    input logic [RW-1:0] rob_head,
    input logic [DISPATCH_WIDTH-1:0] disp_valid,
    input logic [DISPATCH_WIDTH*MEM_IQ_BITS-1:0] disp_uop, // mem_iq_t × D
    input logic [DISPATCH_WIDTH-1:0] disp_src1_ready,
    input logic [DISPATCH_WIDTH-1:0] disp_src2_ready,
    input logic [WB_WIDTH-1:0] wake_valid,
    input logic [WB_WIDTH*PW-1:0] wake_pdst,
    output logic [MIQ_CW-1:0] mem_iq_free,
    output logic cand_valid,
    output logic [MEM_IQ_BITS-1:0] cand_uop, // mem_iq_t
    input logic cand_take
);
endmodule
```

`iq_mem` 保留 16 项 memory uop 存储及每项的 valid、源操作数就绪状态；每拍按 ROB 年龄将一条最老的已就绪指令搬入单项 candidate_reg，下一拍输出给 `issue_sched`。搬入时释放 IQ 槽，背压时保持寄存项，`cand_take` 消费时可同拍补位；squash 当拍屏蔽年轻寄存项并只补入存活指令。端口和 `mem_iq_t` 布局不变。

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
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer CHECKPOINT_DEPTH = 4,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer CIDW = (CHECKPOINT_DEPTH > 1) ? $clog2(CHECKPOINT_DEPTH) : 1,
    parameter integer TAG_BITS = RW,
    parameter integer ALU_EXEC_BITS = TAG_BITS + CIDW + 6 + PW + 32 + 32 + 32 + 32,
    parameter integer RESULT_BITS = TAG_BITS + PW + 32,
    parameter integer RESOLVE_BITS = TAG_BITS + CIDW + 32
) (
    input logic clock,
    input logic reset,
    input logic squash_valid,
    input logic [TAG_BITS-1:0] squash_tag, // rob_tag_t
    input logic [RW-1:0] rob_head,
    input logic exec_valid,
    output logic exec_ready,
    input logic [ALU_EXEC_BITS-1:0] exec_payload, // alu_exec_t
    output logic result_valid,
    input logic result_ready,
    output logic [RESULT_BITS-1:0] result_payload, // result_t
    output logic resolve_valid,
    output logic [RESOLVE_BITS-1:0] resolve_payload // branch_resolve_t
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
    parameter integer TAG_BITS = RW,
    parameter integer MUL_EXEC_BITS = TAG_BITS + 3 + PW + 32 + 32,
    parameter integer RESULT_BITS = TAG_BITS + PW + 32
) (
    input logic clock,
    input logic reset,
    input logic squash_valid,
    input logic [TAG_BITS-1:0] squash_tag, // rob_tag_t
    input logic [RW-1:0] rob_head,
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
    parameter integer FU_SRC_COUNT = ISSUE_WIDTH + 2,
    parameter integer TAG_BITS = RW,
    parameter integer RESULT_BITS = TAG_BITS + PW + 32
) (
    input logic clock,
    input logic reset,
    input logic squash_valid,
    input logic [TAG_BITS-1:0] squash_tag, // rob_tag_t
    input logic [RW-1:0] rob_head,
    input logic [ISSUE_WIDTH-1:0] alu_result_valid,
    output logic [ISSUE_WIDTH-1:0] alu_result_ready,
    input logic [ISSUE_WIDTH*RESULT_BITS-1:0] alu_result_payload, // result_t
    input logic mul_result_valid,
    output logic mul_result_ready,
    input logic [RESULT_BITS-1:0] mul_result_payload, // result_t
    input logic lsu_result_valid,
    output logic lsu_result_ready,
    input logic [RESULT_BITS-1:0] lsu_result_payload, // result_t
    output logic [WB_WIDTH-1:0] done_valid,
    output logic [WB_WIDTH*TAG_BITS-1:0] done_tag, // rob_tag_t × W
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
    parameter integer MEM_EXEC_BITS = TAG_BITS + 3 + MIDW + 32 + 32 + 32,
    parameter integer RESULT_BITS = TAG_BITS + PW + 32,
    parameter integer LD_REQ_BITS = GEN_WIDTH + LIDW + 32,
    parameter integer LD_RSP_BITS = GEN_WIDTH + LIDW + 32,
    parameter integer WRITE_REQ_BITS = 32 + 32 + 4
) (
    input logic clock,
    input logic reset,
    input logic squash_valid,
    input logic [TAG_BITS-1:0] squash_tag, // rob_tag_t
    input logic [RW-1:0] rob_head,
    input logic [GEN_WIDTH-1:0] current_gen,
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

## 14. 顶层连接

- Fetch→Decode→Rename 的包接口不携带 generation；Fetch 在入口按 `{gen,id}` 过滤取指响应，任何重定向都清除尚未派遣的旧前端数据。branch_ctrl.fetch_redirect_* 接 Fetch，valid 同时接 ICache；current_gen 由 branch_ctrl 维护并用于产生重定向目标。
- Rename 的 disp_rob 接 ROB，disp_alu/disp_mem 分别接 IQ，disp_lsq 接 LSU。顶层按 disp_rob.kind 和统一 fire 产生 IQ/LSU 的有效 lane，squash 当拍禁止 fire；不要用前端纠正信号反向门控 fire。
- branch_ctrl 的 checkpoint 候选接 Rename；Rename 的 cp_alloc_* 和 front_redirect_valid/front_redirect_pc 返回控制器。cp_release_mask/restore_cp_id 只接 Rename；ROB、IQ、issue_sched、FU、LSU 和 wb_arb 接 squash_valid/tag，Rename 只接 squash_valid。
- rob_head 接两 IQ、issue_sched、各 FU、LSU、branch_ctrl、wb_arb，作为年龄比较基准；ROB 尾索引和容量返回 Rename。IQ 内部槽号不传出。
- issue_sched 的 ALU/MUL/MEM 执行投影分别接对应入口；每个入口保留完整身份用于局部取消。PRF 读口及窄 wake_* 连接保持。
- 每个 ALU.resolve_* 接 branch_ctrl 的对应 lane，不经过 wb_arb。三个执行源类别的 result_t 接 wb_arb，由 WB 按 squash 年龄边界筛选后仲裁。
- wb_arb.done_tag/valid 只接 ROB；write_* 接 PRF，write_valid/pdst 另接 Rename 和两 IQ 的 wake_*。控制流 npc 不进入该广播。
- ROB.reg_commit_* 只接 Rename（仅携带 old_pdst）；st_start_* 接 LSU，st_done_valid 返回 ROB。LSU/桥的写请求和完成无 generation/ID，不受年轻分支恢复取消。
- Fetch→ICache 使用带 count 的包请求/响应；ICache→桥的 IF 与 LSU→桥的 LD 请求和响应都传递 `{gen,id}`；桥保留并原样返回，客户端按 `{gen,id}` 匹配身份。旧事务与新事务可以同时在桥中存在；generation 只由 branch_ctrl 在每次实际重定向时自增。branch_ctrl.current_gen 直连 LSU；Fetch 只从 fetch_redirect_payload.new_gen 更新本地 fetch_gen。
- 原 run/kill/restore、bridge_idle 和退休 recover_* 连接移除；也不再有 epoch 池相关端口。PRF 不接 squash，写入由 WB 筛选后的 write_valid 控制。外部 AXI 端口保持。

## 15. Instruction Cache 验证

`make test-icache` 运行 Cache/桥和 Fetch/Cache 定向测试，并以 SystemVerilog 2005 编译：覆盖宽度 1/2/4、相联度 1/2/4、行大小 16/32/64 B、单组 Cache、连续命中、填充/Load 竞争、背压、替换、跨行、槽号回绕、多次重定向以及命中/填充返回同拍重定向。还覆盖 IFETCH_OUTSTANDING 小于 D、输出阻塞、非 RAM PC 与 32 位 PC 回绕。

集成验证使用 `make test`、`make perf`、`make synth`。Docker 工具链中可加 `APPIMAGE=` 使用容器原生工具；这些测试不增加 RTL 验证或调试端口。
