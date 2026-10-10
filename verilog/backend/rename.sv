module rename #(
    parameter integer WAKE_WIDTH = 3,
    parameter integer COMMIT_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 48,
    parameter integer IQ_ALU_DEPTH = 7,
    parameter integer IQ_MEM_DEPTH = 4,
    parameter integer LQ_DEPTH = 4,
    parameter integer SQ_DEPTH = 8,
    parameter integer CHECKPOINT_DEPTH = 4
) (
    input logic clock, reset, squash_valid,
    input logic [CIDW-1:0] restore_cp_id,
    input logic [CHECKPOINT_DEPTH-1:0] cp_release_mask,
    input logic [CCW-1:0] cp_free,
    input logic [CIDW-1:0] cp_alloc_id,
    input logic decode_valid,
    output logic decode_ready,
    input logic [DCW-1:0] decode_count,
    input logic [DECODE_BITS-1:0] decode_uop,
    input logic [ROB_CW-1:0] rob_free,
    input logic [RW-1:0] rob_tail,
    input logic [AIQ_CW-1:0] alu_iq_free,
    input logic [MIQ_CW-1:0] mem_iq_free,
    input logic [LQ_CW-1:0] lq_free,
    input logic [SQ_CW-1:0] sq_free,
    input logic [LIDW-1:0] lq_alloc_id,
    input logic [SIDW-1:0] sq_alloc_id,
    output logic disp_valid,
    input logic disp_ready,
    output logic [DCW-1:0] disp_count,
    output logic [ROB_ALLOC_BITS-1:0] disp_rob,
    output logic [ALU_IQ_BITS-1:0] disp_alu,
    output logic [MEM_IQ_BITS-1:0] disp_mem,
    output logic [MEM_ALLOC_BITS-1:0] disp_lsq,
    output logic disp_src1_ready, disp_src2_ready,
    output logic cp_alloc_valid,
    output logic [CP_ALLOC_BITS-1:0] cp_alloc_payload,
    output logic front_redirect_valid,
    output logic [31:0] front_redirect_pc,
    input logic [WAKE_WIDTH-1:0] wake_valid,
    input logic [WAKE_WIDTH*PW-1:0] wake_pdst,
    input logic [COMMIT_WIDTH-1:0] reg_commit_valid,
    input logic [COMMIT_WIDTH*REG_COMMIT_BITS-1:0] reg_commit_payload
);
    localparam integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1;
    localparam integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1;
    localparam integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1;
    localparam integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1;
    localparam integer CIDW = (CHECKPOINT_DEPTH > 1) ? $clog2(CHECKPOINT_DEPTH) : 1;
    localparam integer MIDW = (LIDW > SIDW) ? LIDW : SIDW;
    localparam integer DCW = 1;
    localparam integer ROB_CW = $clog2(ROB_DEPTH + 1);
    localparam integer AIQ_CW = $clog2(IQ_ALU_DEPTH + 1);
    localparam integer MIQ_CW = $clog2(IQ_MEM_DEPTH + 1);
    localparam integer LQ_CW = $clog2(LQ_DEPTH + 1);
    localparam integer SQ_CW = $clog2(SQ_DEPTH + 1);
    localparam integer CCW = $clog2(CHECKPOINT_DEPTH + 1);
    localparam integer TAG_BITS = RW;
    localparam integer DECODE_BITS = 117;
    localparam integer ROB_ALLOC_BITS = PW + 2 + SIDW;
    localparam integer ALU_IQ_BITS = TAG_BITS + CIDW + 6 + PW + PW + PW + 64;
    localparam integer MEM_IQ_BITS = TAG_BITS + 3 + MIDW + PW + PW + 32;
    localparam integer MEM_ALLOC_BITS = 1 + MIDW + TAG_BITS + PW;
    localparam integer CP_ALLOC_BITS = CIDW + TAG_BITS + 32;
    localparam integer REG_COMMIT_BITS = PW;
    // Allocate RAT, ROB, IQ, LSQ and checkpoint at the same dispatch edge.
    reg [PW-1:0] rat [0:31];
    reg [PRF_SIZE-1:0] free_q, ready_q;
    reg [PRF_SIZE-1:0] younger_alloc [0:CHECKPOINT_DEPTH-1];
    reg [CHECKPOINT_DEPTH-1:0] snapshot_valid;
    reg front_fix_pending;
    reg [31:0] front_fix_pc;
    wire [PW-1:0] offer_rat [0:31];
    wire [31:0] pc=decode_uop[116:85], npc=decode_uop[84:53];
    wire [5:0] op=decode_uop[52:47];
    wire [4:0] rs1=decode_uop[46:42], rs2=decode_uop[41:37], rd=decode_uop[36:32];
    wire [31:0] imm=(decode_uop[31:0]);
    wire [PW-1:0] old_pdst=((rd==0?{PW{1'b0}}:rat[rd]));
    wire [PW-1:0] psrc1=(rat[rs1]);
    wire [PW-1:0] psrc2=(rat[rs2]);
    wire front_fix=((!(op>=3 && op<=10) && npc!=pc+32'd4));
    wire rename_hold=reset || squash_valid;
    wire [32*PW-1:0] checkpoint_data, checkpoint_restore;
    for (genvar r=0; r<32; r=r+1) begin : g_checkpoint_data
        assign checkpoint_data[r*PW +: PW]=offer_rat[r];
    end
    generate begin : g_checkpoint_preview
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
    end endgenerate
    always @(posedge clock) begin
        if (reset) front_fix_pending<=0;
        else begin
            front_fix_pending<=fire && front_fix;
            if (fire && front_fix) front_fix_pc<=pc+32'd4;
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
    wire is_branch=op>=3 && op<=10;
    wire is_load=op>=30 && op<=34;
    wire is_store=op>=35 && op<=37;
    wire [1:0] kind=is_branch?2'd1:is_load?2'd2:is_store?2'd3:2'd0;
    wire [MIDW-1:0] mem_id=is_store?MIDW'(sq_alloc_id):MIDW'(lq_alloc_id);
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
    localparam integer CP_CONTROLS=(PRF_SIZE+7)/8;
    wire [CHECKPOINT_DEPTH*CP_CONTROLS-1:0] cp_enable;
    for (genvar c=0; c<CHECKPOINT_DEPTH; c=c+1) begin : g_cp_enable
        (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(CP_CONTROLS)) distribute(
            cp_alloc_valid && cp_alloc_id==CIDW'(c),cp_enable[c*CP_CONTROLS +: CP_CONTROLS]);
    end
    assign disp_valid=!rename_hold && (decode_valid && (rd==0 || free_valid[1])) && queues_fit;
    assign disp_count=1;
    assign decode_ready=!rename_hold && (rd==0 || free_valid[1]) &&
        (queues_fit && disp_ready);
    assign disp_rob={old_pdst,kind,sq_alloc_id};
    assign disp_alu={rob_tail,cp_alloc_id,op,pdst,psrc1,psrc2,pc,imm};
    assign disp_mem={rob_tail,(op[2:0]-3'd6),mem_id,psrc1,psrc2,imm};
    assign disp_lsq={is_store,mem_id,rob_tail,pdst};
    assign cp_alloc_payload={cp_alloc_id,rob_tail,npc};
    assign cp_alloc_valid=fire && is_branch;
    assign front_redirect_valid=(front_fix_pending);
    assign front_redirect_pc=(front_fix_pc);
    always @* begin
        disp_src1_ready=psrc1==0 || ready_q[psrc1];
        disp_src2_ready=psrc2==0 || ready_q[psrc2];
        for (integer w=0; w<WAKE_WIDTH; w=w+1) begin
            if (wake_valid[w] && wake_pdst[w*PW +: PW]==psrc1) disp_src1_ready=1;
            if (wake_valid[w] && wake_pdst[w*PW +: PW]==psrc2) disp_src2_ready=1;
        end
    end
    for (genvar r=0; r<32; r=r+1) begin : g_rat
        if (r==0) begin
            assign rat[r]=0; assign offer_rat[r]=0;
        end else begin
            assign offer_rat[r]=(((rd==r)?pdst:rat[r]));
            always @(posedge clock) begin
                if (reset) rat[r]<=PW'(r);
                else if (rn_control[2*r+1])
                    rat[r]<=checkpoint_restore[r*PW +: PW];
                else if (rn_control[2*r] && rd==r) rat[r]<=pdst;
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
                if (cp_enable[c*CP_CONTROLS+p/8])
                    younger_alloc[c][p]<=0;
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
            for (integer w=0; w<WAKE_WIDTH; w=w+1)
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
