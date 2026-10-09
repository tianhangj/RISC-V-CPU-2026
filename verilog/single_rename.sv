module single_rename #(
    parameter integer DIRECT_RENAME = 0, CHECKPOINT_RAM = 0,
    parameter integer CHECKPOINT_BANKED = 0,
    parameter integer DISPATCH_WIDTH = 1,
    parameter integer WB_WIDTH = 1,
    parameter integer COMMIT_WIDTH = 1,
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
    // RN reserves physical destinations and updates the speculative RAT.
    // DP allocates the ROB/IQ/LSQ/checkpoint atomically one cycle later.
    reg [PW-1:0] rat [0:31];
    reg [PRF_SIZE-1:0] free_q, ready_q;
    reg [PW-1:0] snapshot [0:CHECKPOINT_DEPTH-1][0:31];
    reg [PRF_SIZE-1:0] younger_alloc [0:CHECKPOINT_DEPTH-1];
    reg [CHECKPOINT_DEPTH-1:0] snapshot_valid;
    reg offer_valid, front_fix_reg, front_fix_pending, restore_pending;
    reg [31:0] front_fix_pc;
    reg [31:0] pc_reg, npc_reg, imm_reg;
    reg [5:0] op_reg;
    reg [PW-1:0] pdst_reg, old_reg, ps1_reg, ps2_reg;
    reg [PW-1:0] offer_rat_reg [0:31];
    wire [PW-1:0] offer_rat [0:31];
    wire [31:0] pc=decode_uop[116:85], npc=decode_uop[84:53];
    wire [5:0] op=decode_uop[52:47];
    wire [4:0] rs1=decode_uop[46:42], rs2=decode_uop[41:37], rd=decode_uop[36:32];
    wire [31:0] pc_q=DIRECT_RENAME!=0?pc:pc_reg;
    wire [31:0] npc_q=DIRECT_RENAME!=0?npc:npc_reg;
    wire [31:0] imm_q=DIRECT_RENAME!=0?decode_uop[31:0]:imm_reg;
    wire [5:0] op_q=DIRECT_RENAME!=0?op:op_reg;
    wire [PW-1:0] pdst_q=DIRECT_RENAME!=0?pdst:pdst_reg;
    wire [PW-1:0] old_q=DIRECT_RENAME!=0?(rd==0?{PW{1'b0}}:rat[rd]):old_reg;
    wire [PW-1:0] ps1_q=DIRECT_RENAME!=0?rat[rs1]:ps1_reg;
    wire [PW-1:0] ps2_q=DIRECT_RENAME!=0?rat[rs2]:ps2_reg;
    wire front_fix_q=DIRECT_RENAME!=0?(!(op>=3 && op<=10) && npc!=pc+32'd4):front_fix_reg;
    wire rename_hold=reset || squash_valid || (CHECKPOINT_RAM!=0 && CHECKPOINT_BANKED==0 && restore_pending);
    wire [32*PW-1:0] checkpoint_data, checkpoint_restore;
    for (genvar r=0; r<32; r=r+1) begin : g_checkpoint_data
        assign checkpoint_data[r*PW +: PW]=offer_rat[r];
    end
    generate if (CHECKPOINT_RAM!=0 && CHECKPOINT_BANKED!=0) begin : g_checkpoint_preview
        wire [CHECKPOINT_DEPTH*32*PW-1:0] restored_maps;
        reg last_write;
        reg [CIDW-1:0] last_write_id;
        always @(posedge clock) begin
            if (reset) last_write<=0;
            else last_write<=cp_alloc_valid && !squash_valid;
            if (cp_alloc_valid) last_write_id<=cp_alloc_id;
        end
        for (genvar cp=0; cp<CHECKPOINT_DEPTH; cp=cp+1) begin : g_bank
            wire write_map=cp_alloc_valid && cp_alloc_id==CIDW'(cp) && !squash_valid;
            sram_fakeram #(.DEPTH(1), .WIDTH(32*PW)) maps (
                .clk(clock), .en(1'b1),
                .we(write_map), .wmask(1'b1), .addr(1'b0), .wdata(checkpoint_data),
                .rdata(restored_maps[cp*32*PW +: 32*PW]));
        end
        wire [32*CIDW-1:0] restore_select;
        (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(CIDW), .BRANCHES(32))
            distribute_restore(restore_cp_id,restore_select);
        for (genvar r=0; r<32; r=r+1) begin : g_restore
            assign checkpoint_restore[r*PW +: PW]=
                last_write && restore_select[r*CIDW +: CIDW]==last_write_id ? rat[r] :
                restored_maps[int'(restore_select[r*CIDW +: CIDW])*32*PW+r*PW +: PW];
        end
    end else if (CHECKPOINT_RAM!=0) begin : g_checkpoint_ram
        sram_fakeram #(.DEPTH(CHECKPOINT_DEPTH), .WIDTH(32*PW)) maps (
            .clk(clock), .en(squash_valid || cp_alloc_valid), .we(cp_alloc_valid && !squash_valid),
            .wmask(1'b1), .addr(squash_valid?restore_cp_id:cp_alloc_id),
            .wdata(checkpoint_data), .rdata(checkpoint_restore));
    end else begin : g_no_checkpoint_ram
        assign checkpoint_restore=0;
    end endgenerate
    always @(posedge clock) begin
        if (reset) begin restore_pending<=0; front_fix_pending<=0; end
        else begin
            restore_pending<=squash_valid;
            front_fix_pending<=DIRECT_RENAME!=0 && fire && front_fix;
            if (fire && front_fix) front_fix_pc<=pc_q+32'd4;
        end
    end
    localparam integer LEAVES=2**PW;
    wire [2*LEAVES-1:1] free_valid;
    wire [PW-1:0] free_id [1:2*LEAVES-1];
    for (genvar n=0; n<LEAVES; n=n+1) begin : g_free_leaf
        if (n>0 && n<PRF_SIZE) assign free_valid[LEAVES+n]=free_q[n];
        else assign free_valid[LEAVES+n]=0;
        assign free_id[LEAVES+n]=PW'(n);
    end
    for (genvar n=1; n<LEAVES; n=n+1) begin : g_free_tree
        assign free_valid[n]=free_valid[2*n] || free_valid[2*n+1];
        assign free_id[n]=free_valid[2*n]?free_id[2*n]:free_id[2*n+1];
    end
    wire [PW-1:0] pdst=(rd==0)?{PW{1'b0}}:free_id[1];
    wire is_branch=op_q>=3 && op_q<=10;
    wire is_load=op_q>=30 && op_q<=34;
    wire is_store=op_q>=35 && op_q<=37;
    wire [1:0] kind=is_branch?2'd1:is_load?2'd2:is_store?2'd3:2'd0;
    wire [MIDW-1:0] mem_id=is_store?MIDW'(sq_alloc_id):MIDW'(lq_alloc_id);
    wire front_fix=front_fix_q;
    wire queues_fit=rob_free!=0 && (is_branch?cp_free!=0:1'b1) &&
        ((is_load || is_store)?mem_iq_free!=0:alu_iq_free!=0) &&
        (!is_load || lq_free!=0) && (!is_store || sq_free!=0);
    wire fire=disp_valid && disp_ready;
    wire accept=decode_valid && decode_ready;
    wire [2*PRF_SIZE-1:0] rn_control;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(2), .BRANCHES(PRF_SIZE))
        distribute_rn_control({squash_valid,accept},rn_control);
    wire [PRF_SIZE*CIDW-1:0] restore_index;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(CIDW), .BRANCHES(PRF_SIZE))
        distribute_restore_index(restore_cp_id,restore_index);
    localparam integer CP_RAT_CONTROLS=CHECKPOINT_RAM!=0?0:32;
    localparam integer CP_CONTROLS=CP_RAT_CONTROLS+(PRF_SIZE+7)/8;
    wire [CHECKPOINT_DEPTH*CP_CONTROLS-1:0] cp_enable;
    for (genvar c=0; c<CHECKPOINT_DEPTH; c=c+1) begin : g_cp_enable
        (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(CP_CONTROLS)) distribute(
            cp_alloc_valid && cp_alloc_id==CIDW'(c),cp_enable[c*CP_CONTROLS +: CP_CONTROLS]);
    end
    assign disp_valid=!rename_hold && (DIRECT_RENAME!=0?decode_valid && (rd==0 || free_valid[1]):offer_valid) && queues_fit;
    assign disp_count=1;
    assign decode_ready=!rename_hold && (rd==0 || free_valid[1]) &&
        (DIRECT_RENAME!=0?(queues_fit && disp_ready):((!offer_valid || fire) && !(fire && front_fix)));
    assign disp_rob={old_q,kind,sq_alloc_id};
    assign disp_alu={rob_tail,cp_alloc_id,op_q,pdst_q,ps1_q,ps2_q,pc_q,imm_q};
    assign disp_mem={rob_tail,(op_q[2:0]-3'd6),mem_id,ps1_q,ps2_q,imm_q};
    assign disp_lsq={is_store,mem_id,rob_tail,pdst_q};
    assign cp_alloc_payload={cp_alloc_id,rob_tail,npc_q};
    assign cp_alloc_valid=fire && is_branch;
    assign front_redirect_valid=DIRECT_RENAME!=0?front_fix_pending:(fire && front_fix);
    assign front_redirect_pc=DIRECT_RENAME!=0?front_fix_pc:(pc_q+32'd4);
    always @* begin
        disp_src1_ready=ps1_q==0 || ready_q[ps1_q];
        disp_src2_ready=ps2_q==0 || ready_q[ps2_q];
        for (integer w=0; w<WB_WIDTH; w=w+1) begin
            if (wake_valid[w] && wake_pdst[w*PW +: PW]==ps1_q) disp_src1_ready=1;
            if (wake_valid[w] && wake_pdst[w*PW +: PW]==ps2_q) disp_src2_ready=1;
        end
    end
    always @(posedge clock) begin
        if (reset || squash_valid) offer_valid<=0;
        else begin
            if (fire) offer_valid<=0;
            if (accept) offer_valid<=1;
        end
        if (accept) begin
            pc_reg<=pc; npc_reg<=npc; op_reg<=op; imm_reg<=decode_uop[31:0];
            front_fix_reg<=!(op>=3 && op<=10) && npc!=pc+32'd4;
            ps1_reg<=rat[rs1]; ps2_reg<=rat[rs2]; pdst_reg<=pdst;
            old_reg<=(rd==0)?{PW{1'b0}}:rat[rd];
        end
    end
    for (genvar r=0; r<32; r=r+1) begin : g_rat
        if (r==0) begin
            assign rat[r]=0; assign offer_rat[r]=0;
        end else begin
            assign offer_rat[r]=DIRECT_RENAME!=0?((rd==r)?pdst:rat[r]):offer_rat_reg[r];
            always @(posedge clock) begin
                if (reset) rat[r]<=PW'(r);
                else if (CHECKPOINT_RAM!=0 && CHECKPOINT_BANKED!=0 && rn_control[2*r+1])
                    rat[r]<=checkpoint_restore[r*PW +: PW];
                else if (CHECKPOINT_RAM!=0 && CHECKPOINT_BANKED==0 && restore_pending) rat[r]<=checkpoint_restore[r*PW +: PW];
                else if (CHECKPOINT_RAM==0 && rn_control[2*r+1]) rat[r]<=snapshot[restore_index[r*CIDW +: CIDW]][r];
                else if (rn_control[2*r] && rd==r) rat[r]<=pdst;
                if (rn_control[2*r]) offer_rat_reg[r]<=(rd==r)?pdst:rat[r];
            end
        end
        for (genvar c=0; c<CHECKPOINT_DEPTH; c=c+1) begin : g_snapshot
            if (CHECKPOINT_RAM==0) begin : g_flop_snapshot
                always @(posedge clock)
                    if (cp_enable[c*CP_CONTROLS+r]) snapshot[c][r]<=offer_rat[r];
            end
        end
    end
    for (genvar c=0; c<CHECKPOINT_DEPTH; c=c+1) begin : g_checkpoint
        always @(posedge clock) begin
            if (reset) snapshot_valid[c]<=0;
            else begin
                if (cp_release_mask[c]) snapshot_valid[c]<=0;
                if (cp_alloc_valid && cp_alloc_id==CIDW'(c)) snapshot_valid[c]<=1;
            end
        end
        for (genvar p=0; p<PRF_SIZE; p=p+1) begin : g_allocations
            always @(posedge clock) begin
                if (cp_enable[c*CP_CONTROLS+CP_RAT_CONTROLS+p/8])
                    younger_alloc[c][p]<=DIRECT_RENAME==0 && rn_control[2*p] && pdst==PW'(p) && pdst!=0;
                else if (snapshot_valid[c] && rn_control[2*p] && pdst==PW'(p) && pdst!=0)
                    younger_alloc[c][p]<=1;
            end
        end
    end
    for (genvar p=0; p<PRF_SIZE; p=p+1) begin : g_physical
        reg released, awakened;
        always @* begin
            released=0; awakened=0;
            for (integer c=0; c<COMMIT_WIDTH; c=c+1)
                released=released || (reg_commit_valid[c] && reg_commit_payload[c*PW +: PW]==PW'(p));
            for (integer w=0; w<WB_WIDTH; w=w+1)
                awakened=awakened || (wake_valid[w] && wake_pdst[w*PW +: PW]==PW'(p));
        end
        always @(posedge clock) begin
            if (reset) begin free_q[p]<=p>=32; ready_q[p]<=p<32; end
            else begin
                if (released) free_q[p]<=1;
                if (awakened) ready_q[p]<=1;
                if (rn_control[2*p+1] && younger_alloc[restore_index[p*CIDW +: CIDW]][p]) begin
                    free_q[p]<=1; ready_q[p]<=0;
                end else if (rn_control[2*p] && pdst!=0 && pdst==PW'(p)) begin
                    free_q[p]<=0; ready_q[p]<=0;
                end
            end
        end
    end
endmodule
