module rob #(
    parameter integer DISPATCH_WIDTH = 1,
    parameter integer WB_WIDTH = 2,
    parameter integer COMMIT_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 48,
    parameter integer SQ_DEPTH = 8
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
    localparam integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1;
    localparam integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1;
    localparam integer SIDW = (SQ_DEPTH > 1) ? $clog2(SQ_DEPTH) : 1;
    localparam integer DCW = $clog2(DISPATCH_WIDTH+1);
    localparam integer ROB_CW = $clog2(ROB_DEPTH + 1);
    localparam integer TAG_BITS = RW;
    localparam integer ROB_ALLOC_BITS = PW + 2 + SIDW;
    localparam integer REG_COMMIT_BITS = PW;
    wire [ROB_ALLOC_BITS-1:0] retire_alloc [0:COMMIT_WIDTH-1];
    wire [COMMIT_WIDTH*RW-1:0] metadata_addr;
    wire [COMMIT_WIDTH*ROB_ALLOC_BITS-1:0] metadata_data;
    logic [ROB_DEPTH-1:0] completed;
    reg head_store_started;
    logic [RW-1:0] head_q, tail_q;
    logic [ROB_CW-1:0] count_q;
    logic [ROB_CW-1:0] retire_count, keep_count;
    logic stop_retire;
    logic head_completed;
    integer slot;
    function automatic [RW-1:0] age(input [RW-1:0] tag, input [RW-1:0] head);
        age = tag - head;
    endfunction
    assign rob_head = head_q;
    assign rob_tail = tail_q;
    assign rob_free = ROB_DEPTH - count_q;
    if (DISPATCH_WIDTH==1) begin : g_single_alloc
    (* keep_hierarchy *) payload_ram #(.DEPTH(ROB_DEPTH), .WIDTH(ROB_ALLOC_BITS), .READ_PORTS(COMMIT_WIDTH)) metadata(
        .clock(clock), .reset(reset), .write_valid(rob_free!=0), .write_addr(tail_q),
        .write_data(disp_rob), .read_addr(metadata_addr), .read_data(metadata_data));
    end else begin : g_dual_alloc
        // Consecutive tags have opposite parity, so each SRAM bank still
        // needs only one write port. The read ports retain program order.
        localparam integer BW=(ROB_DEPTH>2)?$clog2(ROB_DEPTH/2):1;
        wire [COMMIT_WIDTH*ROB_ALLOC_BITS-1:0] bank_data [0:1];
        for (genvar bank=0; bank<2; bank=bank+1) begin : g_bank
            wire lane=tail_q[0]!=1'(bank);
            wire [RW-1:0] write_tag=tail_q+RW'(lane);
            wire [COMMIT_WIDTH*BW-1:0] read_addr;
            for (genvar port=0; port<COMMIT_WIDTH; port=port+1) begin : g_addr
                assign read_addr[port*BW +: BW]=BW'(metadata_addr[port*RW +: RW] >> 1);
            end
            (* keep_hierarchy *) payload_ram #(.DEPTH(ROB_DEPTH/2), .WIDTH(ROB_ALLOC_BITS), .READ_PORTS(COMMIT_WIDTH)) metadata (
                .clock(clock), .reset(reset), .write_valid(rob_free>ROB_CW'(lane)),
                .write_addr(BW'(write_tag >> 1)),
                .write_data(disp_rob[int'(lane)*ROB_ALLOC_BITS +: ROB_ALLOC_BITS]),
                .read_addr(read_addr), .read_data(bank_data[bank]));
        end
        for (genvar port=0; port<COMMIT_WIDTH; port=port+1) begin : g_read
            assign metadata_data[port*ROB_ALLOC_BITS +: ROB_ALLOC_BITS]=
                metadata_addr[port*RW]?bank_data[1][port*ROB_ALLOC_BITS +: ROB_ALLOC_BITS]:
                bank_data[0][port*ROB_ALLOC_BITS +: ROB_ALLOC_BITS];
        end
    end
    for (genvar lane=0; lane<COMMIT_WIDTH; lane=lane+1) begin : g_retire_metadata
        assign metadata_addr[lane*RW +: RW]=head_q+RW'(lane);
        assign retire_alloc[lane]=metadata_data[lane*ROB_ALLOC_BITS +: ROB_ALLOC_BITS];
    end

    always_comb begin
        keep_count = count_q;
        if (squash_valid) keep_count = {1'b0, (squash_tag - head_q)} + 1'b1;
        st_start_valid = 0;
        st_start_id = retire_alloc[0][SIDW-1:0];
        head_completed = completed[head_q];
        for (int w = 0; w < WB_WIDTH; w = w + 1)
            if (done_valid[w] && done_tag[w*TAG_BITS +: TAG_BITS] == head_q)
                head_completed = 1;
        if (count_q != 0 && retire_alloc[0][SIDW +: 2] == 2'd3 &&
            head_completed && !head_store_started) st_start_valid = 1;
        retire_count = 0;
        stop_retire = 0;
        reg_commit_valid = 0;
        reg_commit_payload = 0;
        for (int lane = 0; lane < COMMIT_WIDTH; lane = lane + 1) begin
            slot = (head_q + lane) % ROB_DEPTH;
            if (!stop_retire && lane < keep_count) begin
                if (retire_alloc[lane][SIDW +: 2] == 2'd3) begin
                    if (lane == 0 && (head_store_started || st_start_valid) && st_done_valid)
                        retire_count = retire_count + 1'b1;
                    else stop_retire = 1;
                end else if (completed[slot]) begin
                    retire_count = retire_count + 1'b1;
                    if (retire_alloc[lane][ROB_ALLOC_BITS-1 -: PW] != 0) begin
                        reg_commit_valid[lane] = 1;
                        reg_commit_payload[lane*PW +: PW] = retire_alloc[lane][ROB_ALLOC_BITS-1 -: PW];
                    end
                end else stop_retire = 1;
            end
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            head_q <= 0;
            tail_q <= 0;
            count_q <= 0;
            completed <= 0;
            head_store_started<=0;
        end else begin
            // Only the current head can own an authorized Store. Every
            // completion retires it at this edge, so no per-slot flags remain.
            if (retire_count!=0) head_store_started<=0;
            else if (st_start_valid) head_store_started<=1;
            for (int w = 0; w < WB_WIDTH; w = w + 1) begin
                if (done_valid[w] &&
                    (age(done_tag[w*TAG_BITS +: TAG_BITS], head_q) < count_q) &&
                    (!squash_valid ||
                     (age(done_tag[w*TAG_BITS +: TAG_BITS], head_q) < keep_count)))
                    completed[done_tag[w*TAG_BITS +: TAG_BITS]] <= 1;
            end
            if (disp_fire && !squash_valid) begin
                for (int lane=0; lane<DISPATCH_WIDTH; lane=lane+1) begin
                    if (lane < disp_count) begin
                        completed[(tail_q + lane) % ROB_DEPTH] <= 0;
                    end
                end
            end
            head_q <= head_q + retire_count;
            if (squash_valid) begin
                tail_q <= squash_tag + 1'b1;
                count_q <= keep_count - retire_count;
            end else if (disp_fire) begin
                tail_q <= tail_q + disp_count;
                count_q <= count_q + disp_count - retire_count;
            end else count_q <= count_q - retire_count;
        end
    end
endmodule
