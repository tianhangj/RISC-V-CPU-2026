// Two-wide dispatch with one arithmetic and one memory allocation per cycle.
// The frontend feeds a skid queue. Packets are ordered
// prefixes; a branch or frontend correction always terminates a packet.
module rename_dual #(
    parameter integer DECODE_WIDTH = 1,
    parameter integer WAKE_WIDTH = 3,
    parameter integer COMMIT_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 56,
    parameter integer LQ_DEPTH = 8,
    parameter integer SQ_DEPTH = 8,
    parameter integer CHECKPOINT_DEPTH = 4
) (
    input wire clock, reset, squash_valid,
    input wire [CIDW-1:0] restore_cp_id,
    input wire [CHECKPOINT_DEPTH-1:0] cp_release_mask,
    input wire cp_has_free,
    input wire [CIDW-1:0] cp_alloc_id,
    input wire decode_valid,
    output wire decode_ready,
    input wire [$clog2(DECODE_WIDTH+1)-1:0] decode_count,
    input wire [DECODE_WIDTH*117-1:0] decode_uop,
    input wire [ROB_CW-1:0] rob_free,
    input wire [RW-1:0] rob_tail,
    input wire alu_iq_has_free, mem_iq_has_free, lq_has_free, sq_has_free,
    input wire alu2_iq_has_free,
    input wire [LIDW-1:0] lq_alloc_id,
    input wire [SIDW-1:0] sq_alloc_id,
    output wire disp_valid,
    input wire disp_ready,
    output wire [1:0] disp_count,
    output wire [2*ROB_ALLOC_BITS-1:0] disp_rob,
    output wire [ALU_IQ_BITS-1:0] disp_alu,
    output wire [ALU_IQ_BITS-1:0] disp_alu2,
    output wire alu2_dispatch,
    output wire alu2_src1_ready, alu2_src2_ready,
    output wire [MEM_IQ_BITS-1:0] disp_mem,
    output wire [MEM_ALLOC_BITS-1:0] disp_lsq,
    // Readiness is indexed by queue: arithmetic=0, memory=1.
    output wire [1:0] disp_src1_ready, disp_src2_ready,
    output wire cp_alloc_valid,
    output wire [CP_ALLOC_BITS-1:0] cp_alloc_payload,
    output wire front_redirect_valid,
    output reg [31:0] front_redirect_pc,
    input wire [WAKE_WIDTH-1:0] wake_valid,
    input wire [WAKE_WIDTH*PW-1:0] wake_pdst,
    input wire [COMMIT_WIDTH-1:0] reg_commit_valid,
    input wire [COMMIT_WIDTH*PW-1:0] reg_commit_payload
);
    localparam integer RW = $clog2(ROB_DEPTH);
    localparam integer PW = $clog2(PRF_SIZE);
    localparam integer LIDW = (LQ_DEPTH>1)?$clog2(LQ_DEPTH):1;
    localparam integer SIDW = $clog2(SQ_DEPTH);
    localparam integer CIDW = (CHECKPOINT_DEPTH>1)?$clog2(CHECKPOINT_DEPTH):1;
    localparam integer MIDW = (LIDW>SIDW)?LIDW:SIDW;
    localparam integer ROB_CW = $clog2(ROB_DEPTH+1);
    localparam integer ROB_ALLOC_BITS = PW+2+SIDW;
    localparam integer ALU_IQ_BITS = RW+CIDW+6+3*PW+64;
    localparam integer MEM_IQ_BITS = RW+3+MIDW+2*PW+32;
    localparam integer MEM_ALLOC_BITS = 1+MIDW+RW+PW;
    localparam integer CP_ALLOC_BITS = CIDW+RW+32;

    localparam integer QUEUE_DEPTH=2*DECODE_WIDTH;
    localparam integer QCW=$clog2(QUEUE_DEPTH+1);
    reg [116:0] queued [0:QUEUE_DEPTH-1];
    reg [QCW-1:0] queued_count;
    reg front_fix_pending;
    reg [PW-1:0] rat [0:31];
    reg [PRF_SIZE-1:0] free_q, ready_q;
    reg [PRF_SIZE-1:0] younger_alloc [0:CHECKPOINT_DEPTH-1];
    reg [CHECKPOINT_DEPTH-1:0] snapshot_valid;
    wire [31:0] pc [0:1], npc [0:1], imm [0:1];
    wire [5:0] op [0:1];
    wire [4:0] rs1 [0:1], rs2 [0:1], rd [0:1];
    wire [1:0] kind [0:1];
    wire [1:0] memory_op, branch_op, front_fix, fits;
    wire [1:0] primary_only;
    reg [PW-1:0] pdst [0:1];
    wire [PW-1:0] ps1 [0:1], ps2 [0:1], old_pdst [0:1];
    wire [RW-1:0] tag [0:1];
    reg found0, found1;
    reg [PW-1:0] free0, free1;
    always @* begin
        found0=0; found1=0; free0=0; free1=0;
        for (integer p=1; p<PRF_SIZE; p=p+1)
            if (free_q[p]) begin
                if (!found0) begin found0=1; free0=PW'(p); end
                else if (!found1) begin found1=1; free1=PW'(p); end
            end
        pdst[0]=(rd[0]==0)?PW'(0):free0;
        pdst[1]=(rd[1]==0)?PW'(0):((rd[0]==0)?free0:free1);
    end
    for (genvar lane=0; lane<2; lane=lane+1) begin : g_decode
        assign {pc[lane],npc[lane],op[lane],rs1[lane],rs2[lane],rd[lane],imm[lane]}=queued[lane];
        assign branch_op[lane]=op[lane]>=3 && op[lane]<=10;
        assign memory_op[lane]=op[lane]>=30 && op[lane]<=37;
        assign primary_only[lane]=branch_op[lane] || op[lane]>=38;
        assign kind[lane]=branch_op[lane]?2'd1:
            (op[lane]>=30 && op[lane]<=34)?2'd2:memory_op[lane]?2'd3:2'd0;
        assign front_fix[lane]=!branch_op[lane] && npc[lane]!=pc[lane]+32'd4;
        assign fits[lane]=(memory_op[lane]?mem_iq_has_free:alu_iq_has_free) &&
            (!branch_op[lane] || cp_has_free) &&
            (kind[lane]!=2 || lq_has_free) && (kind[lane]!=3 || sq_has_free);
        assign tag[lane]=rob_tail+RW'(lane);
    end
    // Lane 1 observes the mapping written by lane 0, including WAW's old map.
    assign ps1[0]=rat[rs1[0]];
    assign ps2[0]=rat[rs2[0]];
    assign old_pdst[0]=(rd[0]==0)?PW'(0):rat[rd[0]];
    assign ps1[1]=(rd[0]!=0 && rs1[1]==rd[0])?pdst[0]:rat[rs1[1]];
    assign ps2[1]=(rd[0]!=0 && rs2[1]==rd[0])?pdst[0]:rat[rs2[1]];
    assign old_pdst[1]=(rd[1]==0)?PW'(0):
        (rd[0]!=0 && rd[1]==rd[0])?pdst[0]:rat[rd[1]];
    wire pair_regs_fit=(rd[1]==0) || ((rd[0]==0)?found0:found1);
    wire two_alu=!memory_op[0] && !memory_op[1];
    wire pair=queued_count>=2 && !branch_op[0] && !front_fix[0] &&
        (memory_op[0]!=memory_op[1] ||
         (two_alu && alu2_iq_has_free && !(primary_only[0] && primary_only[1]))) &&
        rob_free>=2 && fits[1] && pair_regs_fit;
    assign disp_count=pair?2'd2:2'd1;
    assign disp_valid=!reset && !squash_valid && !front_fix_pending &&
        queued_count!=0 && rob_free!=0 && fits[0] && (rd[0]==0 || found0);
    wire fire=disp_valid && disp_ready;
    wire [QCW-1:0] remaining=queued_count-(fire?QCW'(disp_count):QCW'(0));
    assign decode_ready=!reset && !squash_valid && !front_fix_pending &&
        int'(remaining)+int'(decode_count)<=QUEUE_DEPTH;
    wire accept=decode_valid && decode_ready;
    always @(posedge clock) begin
        if (reset || squash_valid || front_fix_pending) queued_count<=0;
        else begin
            queued_count<=remaining+(accept?QCW'(decode_count):QCW'(0));
            for (integer slot=0; slot<QUEUE_DEPTH; slot=slot+1) begin
                if (fire && slot<int'(remaining))
                    queued[slot]<=queued[slot+int'(disp_count)];
                for (integer lane=0; lane<DECODE_WIDTH; lane=lane+1)
                    if (accept && lane<int'(decode_count) && slot==int'(remaining)+lane)
                        queued[slot]<=decode_uop[lane*117 +: 117];
            end
        end
    end

    wire a_lane=pair && (memory_op[0] || (two_alu && primary_only[1]));
    wire a2_lane=!a_lane;
    assign alu2_dispatch=pair && two_alu;
    wire m_lane=!memory_op[0] && pair;
    wire b_lane=pair;
    wire [MIDW-1:0] mem_id=(kind[m_lane]==3)?MIDW'(sq_alloc_id):MIDW'(lq_alloc_id);
    assign disp_rob={{old_pdst[1],kind[1],sq_alloc_id},{old_pdst[0],kind[0],sq_alloc_id}};
    assign disp_alu={tag[a_lane],cp_alloc_id,op[a_lane],pdst[a_lane],
        ps1[a_lane],ps2[a_lane],pc[a_lane],imm[a_lane]};
    assign disp_alu2={tag[a2_lane],cp_alloc_id,op[a2_lane],pdst[a2_lane],
        ps1[a2_lane],ps2[a2_lane],pc[a2_lane],imm[a2_lane]};
    assign disp_mem={tag[m_lane],(op[m_lane][2:0]-3'd6),mem_id,
        ps1[m_lane],ps2[m_lane],imm[m_lane]};
    assign disp_lsq={kind[m_lane]==3,mem_id,tag[m_lane],pdst[m_lane]};
    wire [1:0] r1, r2;
    for (genvar lane=0; lane<2; lane=lane+1) begin : g_source_ready
        assign r1[lane]=ps1[lane]==0 || (ready_q[ps1[lane]] &&
            !(lane==1 && rd[0]!=0 && rs1[lane]==rd[0]));
        assign r2[lane]=ps2[lane]==0 || (ready_q[ps2[lane]] &&
            !(lane==1 && rd[0]!=0 && rs2[lane]==rd[0]));
    end
    assign disp_src1_ready={r1[m_lane],r1[a_lane]};
    assign disp_src2_ready={r2[m_lane],r2[a_lane]};
    assign alu2_src1_ready=r1[a2_lane];
    assign alu2_src2_ready=r2[a2_lane];
    assign cp_alloc_valid=fire && branch_op[b_lane];
    assign cp_alloc_payload={cp_alloc_id,tag[b_lane],npc[b_lane]};
    assign front_redirect_valid=front_fix_pending;
    always @(posedge clock) begin
        if (reset || squash_valid) front_fix_pending<=0;
        else front_fix_pending<=fire && front_fix[b_lane];
        if (fire && front_fix[b_lane]) front_redirect_pc<=pc[b_lane]+32'd4;
    end

    wire [32*PW-1:0] checkpoint_data, checkpoint_restore;
    wire [CHECKPOINT_DEPTH*32*PW-1:0] restored_maps;
    reg last_write;
    reg [CIDW-1:0] last_write_id;
    always @(posedge clock) begin
        if (reset) last_write<=0;
        else last_write<=cp_alloc_valid;
        if (cp_alloc_valid) last_write_id<=cp_alloc_id;
    end
    for (genvar r=0; r<32; r=r+1) begin : g_rat
        wire [PW-1:0] after0=(r!=0 && rd[0]==r)?pdst[0]:rat[r];
        wire [PW-1:0] after1=(r!=0 && pair && rd[1]==r)?pdst[1]:after0;
        assign checkpoint_data[r*PW +: PW]=after1;
        assign checkpoint_restore[r*PW +: PW]=
            last_write && restore_cp_id==last_write_id?rat[r]:
            restored_maps[int'(restore_cp_id)*32*PW+r*PW +: PW];
        always @(posedge clock) begin
            if (reset) rat[r]<=PW'(r);
            else if (r==0) rat[r]<=0;
            else if (squash_valid) rat[r]<=checkpoint_restore[r*PW +: PW];
            else if (fire) rat[r]<=after1;
        end
    end
    wire [PRF_SIZE-1:0] allocated;
    for (genvar p=0; p<PRF_SIZE; p=p+1) begin : g_physical
        assign allocated[p]=p!=0 && (pdst[0]==PW'(p) || (pair && pdst[1]==PW'(p)));
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
                if (squash_valid && younger_alloc[restore_cp_id][p]) begin
                    free_q[p]<=1; ready_q[p]<=0;
                end else if (fire && allocated[p]) begin
                    free_q[p]<=0; ready_q[p]<=0;
                end
            end
        end
    end
    for (genvar cp=0; cp<CHECKPOINT_DEPTH; cp=cp+1) begin : g_checkpoint
        sram_fakeram #(.DEPTH(1), .WIDTH(32*PW)) maps (
            .clk(clock), .en(1'b1), .we(cp_alloc_valid && cp_alloc_id==CIDW'(cp)),
            .wmask(1'b1), .addr(1'b0), .wdata(checkpoint_data),
            .rdata(restored_maps[cp*32*PW +: 32*PW]));
        always @(posedge clock) begin
            if (reset) snapshot_valid[cp]<=0;
            else begin
                if (cp_release_mask[cp]) snapshot_valid[cp]<=0;
                if (cp_alloc_valid && cp_alloc_id==CIDW'(cp)) snapshot_valid[cp]<=1;
            end
            if (cp_alloc_valid && cp_alloc_id==CIDW'(cp)) younger_alloc[cp]<=0;
            else if (snapshot_valid[cp] && fire) younger_alloc[cp]<=younger_alloc[cp] | allocated;
        end
    end
endmodule
