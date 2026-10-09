// Single issue: choose a ready IQ entry and capture its operands at one edge.
// ALU wakeup precedes its registered result by one cycle. Source identities
// remain with the operands so the result can be forwarded at execution.
module single_issue #(
    parameter integer ROB_DEPTH=32, PRF_SIZE=64, LQ_DEPTH=8, SQ_DEPTH=8,
    parameter integer CHECKPOINT_DEPTH=4, FORWARD_WIDTH=3,
    parameter integer EARLY_BRANCH=0, DELAYED_FORWARD=0,
    parameter integer REGISTERED_LOAD_BRANCH=0, SNAPSHOT_LOAD_FORWARD=0,
    parameter integer RW=$clog2(ROB_DEPTH), PW=$clog2(PRF_SIZE),
    parameter integer LIDW=(LQ_DEPTH>1)?$clog2(LQ_DEPTH):1,
    parameter integer SIDW=(SQ_DEPTH>1)?$clog2(SQ_DEPTH):1,
    parameter integer MIDW=(LIDW>SIDW)?LIDW:SIDW,
    parameter integer CIDW=(CHECKPOINT_DEPTH>1)?$clog2(CHECKPOINT_DEPTH):1,
    parameter integer ALU_IQ_BITS=RW+CIDW+6+3*PW+64,
    parameter integer MEM_IQ_BITS=RW+3+MIDW+2*PW+32,
    parameter integer ALU_EXEC_BITS=RW+CIDW+6+PW+128,
    parameter integer MUL_EXEC_BITS=RW+3+PW+64,
    parameter integer MEM_EXEC_BITS=RW+3+MIDW+96
) (
    input wire clock, reset, squash_valid,
    input wire [RW-1:0] squash_tag, rob_head,
    input wire alu_cand_valid, mem_cand_valid, mem_cand_src2_ready,
    input wire [ALU_IQ_BITS-1:0] alu_cand_uop,
    input wire [MEM_IQ_BITS-1:0] mem_cand_uop,
    output wire alu_cand_take, mem_cand_take,
    output wire [2*PW-1:0] rd_addr,
    input wire [63:0] rd_data,
    input wire [FORWARD_WIDTH-1:0] forward_valid,
    input wire [FORWARD_WIDTH*PW-1:0] forward_pdst,
    input wire [FORWARD_WIDTH*32-1:0] forward_value,
    output wire mem_store_data_valid,
    output wire [PW-1:0] mem_store_psrc,
    output wire branch_exec_valid,
    output reg [31:0] branch_operand1, branch_operand2,
    output wire early_wake_valid,
    output wire [PW-1:0] early_wake_pdst,
    output wire alu_exec_valid, mul_exec_valid, mem_exec_valid,
    output wire mem_exec_preview_valid,
    input wire alu_exec_ready, mul_exec_ready, mem_exec_ready,
    output wire [ALU_EXEC_BITS-1:0] alu_exec_payload,
    output wire [MUL_EXEC_BITS-1:0] mul_exec_payload,
    output wire [MEM_EXEC_BITS-1:0] mem_exec_payload
);
    (* keep *) reg [2:0] busy;
    (* keep *) reg branch_announced;
    reg [FORWARD_WIDTH-1:0] last_valid;
    reg [FORWARD_WIDTH*PW-1:0] last_pdst;
    reg [FORWARD_WIDTH*32-1:0] last_value;
    always @(posedge clock) begin
        if (reset) last_valid<=0;
        else last_valid<=forward_valid;
        last_pdst<=forward_pdst; last_value<=forward_value;
    end
    reg mem_data_ready;
    reg mem_data_forward;
    reg [ALU_EXEC_BITS-1:0] alu_q;
    reg [MUL_EXEC_BITS-1:0] mul_q;
    reg [MEM_EXEC_BITS-1:0] mem_q;
    reg [PW-1:0] src1 [0:2], src2 [0:2];
    reg [31:0] operand1 [0:2], operand2 [0:2];
    reg [31:0] forwarded1 [0:2], forwarded2 [0:2];
    wire [2:0] ready={mem_exec_ready,mul_exec_ready,alu_exec_ready};
    wire [5:0] alu_op=alu_cand_uop[64+3*PW +: 6];
    wire is_mul=alu_op>=38 && alu_op<=45;
    wire [RW-1:0] alu_tag=alu_cand_uop[ALU_IQ_BITS-1 -: RW];
    wire [RW-1:0] mem_tag=mem_cand_uop[MEM_IQ_BITS-1 -: RW];
    function automatic survives(input [RW-1:0] tag);
        survives=!squash_valid || RW'(tag-rob_head)<=RW'(squash_tag-rob_head);
    endfunction
    wire alu_offer=alu_cand_valid &&
        (is_mul?(!busy[1] || mul_exec_ready):(!busy[0] || alu_exec_ready));
    wire mem_offer=mem_cand_valid && (!busy[2] || mem_exec_ready);
    // Compare ring positions directly: wrapping below head reverses the
    // numeric relation only when the two candidates straddle head.
    wire mem_older=(mem_tag<alu_tag) ^ (mem_tag<rob_head) ^ (alu_tag<rob_head);
    wire select_mem=mem_offer && (!alu_offer || mem_older);
    assign alu_cand_take=!reset && alu_offer && !select_mem;
    assign mem_cand_take=!reset && select_mem;
    assign rd_addr=select_mem ?
        {mem_cand_uop[32 +: PW],mem_cand_uop[32+PW +: PW]} :
        {alu_cand_uop[64 +: PW],alu_cand_uop[64+PW +: PW]};
    assign alu_exec_valid=!reset && busy[0] && survives(alu_q[ALU_EXEC_BITS-1 -: RW]);
    assign mul_exec_valid=!reset && busy[1] && survives(mul_q[MUL_EXEC_BITS-1 -: RW]);
    assign mem_exec_preview_valid=!reset && busy[2];
    assign mem_exec_valid=!reset && busy[2] && survives(mem_q[MEM_EXEC_BITS-1 -: RW]);
    // Cancellation removes dependent younger IQ entries at the same edge.
    // Do not route squash through this predictive wakeup's selection path.
    assign early_wake_valid=!reset && busy[0] && alu_exec_ready;
    // Resolve once, independently of completion backpressure.
    assign branch_exec_valid=EARLY_BRANCH!=0 ? (!reset && busy[0] && !branch_announced) : early_wake_valid;
    assign early_wake_pdst=alu_q[128 +: PW];
    assign mem_store_psrc=src2[2];
    assign mem_store_data_valid=mem_data_ready || mem_data_forward;
    assign alu_exec_payload={alu_q[ALU_EXEC_BITS-1:64],forwarded1[0],forwarded2[0]};
    assign mul_exec_payload={mul_q[MUL_EXEC_BITS-1:64],forwarded1[1],forwarded2[1]};
    assign mem_exec_payload={mem_q[MEM_EXEC_BITS-1:96],forwarded1[2],mem_q[63:32],forwarded2[2]};
    // Bound each completion-match net to a few operand chunks. Branch and
    // arithmetic forwarding retain separate buffers even when their match
    // predicates are identical.
    wire [3*FORWARD_WIDTH*4-1:0] current1_select, current2_select;
    wire [3*FORWARD_WIDTH*4-1:0] previous1_select, previous2_select;
    for (genvar lane=0; lane<3; lane=lane+1) begin : g_forward_lane
        for (genvar w=0; w<FORWARD_WIDTH; w=w+1) begin : g_completion
            localparam integer BASE=(lane*FORWARD_WIDTH+w)*4;
            wire current1=forward_valid[w] && src1[lane]!=0 && src1[lane]==forward_pdst[w*PW +: PW];
            wire current2=forward_valid[w] && src2[lane]!=0 && src2[lane]==forward_pdst[w*PW +: PW];
            wire previous1=DELAYED_FORWARD!=0 && last_valid[w] && src1[lane]!=0 && src1[lane]==last_pdst[w*PW +: PW];
            wire previous2=DELAYED_FORWARD!=0 && last_valid[w] && src2[lane]!=0 && src2[lane]==last_pdst[w*PW +: PW];
            (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(4)) current_src1(current1,current1_select[BASE +: 4]);
            (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(4)) current_src2(current2,current2_select[BASE +: 4]);
            (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(4)) previous_src1(previous1,previous1_select[BASE +: 4]);
            (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(4)) previous_src2(previous2,previous2_select[BASE +: 4]);
        end
    end
    always @* begin
        branch_operand1=operand1[0]; branch_operand2=operand2[0];
        for (integer w=0; w<FORWARD_WIDTH; w=w+1)
            for (integer half=0; half<2; half=half+1) begin
                if (previous1_select[w*4+2+half]) branch_operand1[half*16 +: 16]=last_value[w*32+half*16 +: 16];
                if (previous2_select[w*4+2+half]) branch_operand2[half*16 +: 16]=last_value[w*32+half*16 +: 16];
            end
        for (integer w=0; w<FORWARD_WIDTH; w=w+1)
            for (integer half=0; half<2; half=half+1)
                if ((REGISTERED_LOAD_BRANCH==0 && SNAPSHOT_LOAD_FORWARD==0) || w<FORWARD_WIDTH-1) begin
                    if (current1_select[w*4+2+half]) branch_operand1[half*16 +: 16]=forward_value[w*32+half*16 +: 16];
                    if (current2_select[w*4+2+half]) branch_operand2[half*16 +: 16]=forward_value[w*32+half*16 +: 16];
                end
        mem_data_forward=0;
        if (DELAYED_FORWARD!=0)
            for (integer w=0; w<FORWARD_WIDTH; w=w+1)
                if (last_valid[w] && src2[2]==last_pdst[w*PW +: PW]) mem_data_forward=1;
        for (integer w=0; w<FORWARD_WIDTH; w=w+1)
            if (forward_valid[w] && src2[2]==forward_pdst[w*PW +: PW]) mem_data_forward=1;
        for (integer lane=0; lane<3; lane=lane+1) begin
            forwarded1[lane]=operand1[lane]; forwarded2[lane]=operand2[lane];
            for (integer w=0; w<FORWARD_WIDTH; w=w+1)
                for (integer half=0; half<2; half=half+1) begin
                    if (previous1_select[(lane*FORWARD_WIDTH+w)*4+half])
                        forwarded1[lane][half*16 +: 16]=last_value[w*32+half*16 +: 16];
                    if (previous2_select[(lane*FORWARD_WIDTH+w)*4+half])
                        forwarded2[lane][half*16 +: 16]=last_value[w*32+half*16 +: 16];
                end
            for (integer w=0; w<FORWARD_WIDTH; w=w+1)
                for (integer half=0; half<2; half=half+1) begin
                    if (!(SNAPSHOT_LOAD_FORWARD!=0 && w==FORWARD_WIDTH-1) &&
                        !(REGISTERED_LOAD_BRANCH!=0 && lane==0 && alu_q[128+PW +: 6]>=3 &&
                          alu_q[128+PW +: 6]<=10 && w==FORWARD_WIDTH-1) &&
                        current1_select[(lane*FORWARD_WIDTH+w)*4+half])
                        forwarded1[lane][half*16 +: 16]=forward_value[w*32+half*16 +: 16];
                    if (!(SNAPSHOT_LOAD_FORWARD!=0 && lane!=2 && w==FORWARD_WIDTH-1) &&
                        !(REGISTERED_LOAD_BRANCH!=0 && lane==0 && alu_q[128+PW +: 6]>=3 &&
                          alu_q[128+PW +: 6]<=10 && w==FORWARD_WIDTH-1) &&
                        current2_select[(lane*FORWARD_WIDTH+w)*4+half])
                        forwarded2[lane][half*16 +: 16]=forward_value[w*32+half*16 +: 16];
                end
        end
    end
    wire [ALU_EXEC_BITS-1:0] next_alu_q={alu_cand_uop[ALU_IQ_BITS-1:64+2*PW],alu_cand_uop[63:0],64'b0};
    wire [MUL_EXEC_BITS-1:0] next_mul_q={alu_tag,(alu_op[2:0]-3'd6),alu_cand_uop[64+2*PW +: PW],64'b0};
    wire [MEM_EXEC_BITS-1:0] next_mem_q={mem_cand_uop[MEM_IQ_BITS-1:32+2*PW],32'b0,mem_cand_uop[31:0],32'b0};
    wire [9:0] alu_capture, mul_capture, mem_capture;
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(10))
        distribute_alu_capture(alu_cand_take && !is_mul, alu_capture);
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(10))
        distribute_mul_capture(alu_cand_take && is_mul, mul_capture);
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(10))
        distribute_mem_capture(mem_cand_take, mem_capture);
    for (genvar chunk=0; chunk<5; chunk=chunk+1) begin : g_capture_words
        localparam integer OFFSET=32*chunk;
        localparam integer ACOUNT=(ALU_EXEC_BITS-OFFSET>32)?32:ALU_EXEC_BITS-OFFSET;
        localparam integer MCOUNT=(MUL_EXEC_BITS-OFFSET>32)?32:MUL_EXEC_BITS-OFFSET;
        localparam integer LCOUNT=(MEM_EXEC_BITS-OFFSET>32)?32:MEM_EXEC_BITS-OFFSET;
        if (ACOUNT>0) always @(posedge clock)
            if (alu_capture[chunk+1]) alu_q[OFFSET +: ACOUNT]<=next_alu_q[OFFSET +: ACOUNT];
        if (MCOUNT>0) always @(posedge clock)
            if (mul_capture[chunk+1]) mul_q[OFFSET +: MCOUNT]<=next_mul_q[OFFSET +: MCOUNT];
        if (LCOUNT>0) always @(posedge clock)
            if (mem_capture[chunk+1]) mem_q[OFFSET +: LCOUNT]<=next_mem_q[OFFSET +: LCOUNT];
    end
    always @(posedge clock) begin
        if (reset) begin busy<=0; branch_announced<=0; end
        else begin
            if (branch_exec_valid) branch_announced<=1;
            if (mem_data_forward) mem_data_ready<=1;
            if (ready[0] || !survives(alu_q[ALU_EXEC_BITS-1 -: RW])) busy[0]<=0;
            if (ready[1] || !survives(mul_q[MUL_EXEC_BITS-1 -: RW])) busy[1]<=0;
            if (ready[2] || !survives(mem_q[MEM_EXEC_BITS-1 -: RW])) busy[2]<=0;
            // Preserve forwarded values even when the execution unit stalls.
            for (integer lane=0; lane<3; lane=lane+1) begin
                operand1[lane]<=forwarded1[lane]; operand2[lane]<=forwarded2[lane];
            end
            if (mul_capture[0]) busy[1]<=survives(alu_tag);
            if (alu_capture[0]) begin busy[0]<=survives(alu_tag); branch_announced<=0; end
            if (mem_capture[0]) begin busy[2]<=survives(mem_tag); mem_data_ready<=mem_cand_src2_ready; end
            if (mul_capture[6]) begin src1[1]<=rd_addr[0 +: PW]; src2[1]<=rd_addr[PW +: PW]; end
            if (alu_capture[6]) begin src1[0]<=rd_addr[0 +: PW]; src2[0]<=rd_addr[PW +: PW]; end
            if (mem_capture[6]) begin src1[2]<=rd_addr[0 +: PW]; src2[2]<=rd_addr[PW +: PW]; end
            if (mul_capture[7]) operand1[1]<=rd_data[31:0];
            if (mul_capture[8]) operand2[1]<=rd_data[63:32];
            if (alu_capture[7]) operand1[0]<=rd_data[31:0];
            if (alu_capture[8]) operand2[0]<=rd_data[63:32];
            if (mem_capture[7]) operand1[2]<=rd_data[31:0];
            if (mem_capture[8]) operand2[2]<=rd_data[63:32];
        end
    end
endmodule
