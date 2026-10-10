module rob #(
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
    input logic [ROB_ALLOC_BITS-1:0] disp_rob,
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
    localparam integer DCW = 1;
    localparam integer ROB_CW = $clog2(ROB_DEPTH + 1);
    localparam integer TAG_BITS = RW;
    localparam integer ROB_ALLOC_BITS = PW + 2 + SIDW;
    localparam integer REG_COMMIT_BITS = PW;
    logic [ROB_ALLOC_BITS-1:0] alloc [0:ROB_DEPTH-1];
    logic [ROB_DEPTH-1:0] completed, store_started, store_responded;
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

    always_comb begin
        keep_count = count_q;
        if (squash_valid) keep_count = {1'b0, (squash_tag - head_q)} + 1'b1;
        st_start_valid = 0;
        st_start_id = alloc[head_q][SIDW-1:0];
        head_completed = completed[head_q];
        for (int w = 0; w < WB_WIDTH; w = w + 1)
            if (done_valid[w] && done_tag[w*TAG_BITS +: TAG_BITS] == head_q)
                head_completed = 1;
        if (count_q != 0 && alloc[head_q][SIDW +: 2] == 2'd3 &&
            head_completed && !store_started[head_q]) st_start_valid = 1;
        retire_count = 0;
        stop_retire = 0;
        reg_commit_valid = 0;
        reg_commit_payload = 0;
        for (int lane = 0; lane < COMMIT_WIDTH; lane = lane + 1) begin
            slot = (head_q + lane) % ROB_DEPTH;
            if (!stop_retire && lane < keep_count) begin
                if (alloc[slot][SIDW +: 2] == 2'd3) begin
                    if (lane == 0 && (store_responded[slot] ||
                        (store_started[slot] && st_done_valid) ||
                        (st_start_valid && st_done_valid)))
                        retire_count = retire_count + 1'b1;
                    else stop_retire = 1;
                end else if (completed[slot]) begin
                    retire_count = retire_count + 1'b1;
                    if (alloc[slot][ROB_ALLOC_BITS-1 -: PW] != 0) begin
                        reg_commit_valid[lane] = 1;
                        reg_commit_payload[lane*PW +: PW] = alloc[slot][ROB_ALLOC_BITS-1 -: PW];
                    end
                end else stop_retire = 1;
            end
        end
    end

    for (genvar s = 0; s < ROB_DEPTH; s = s+1) begin : g_prepare_alloc
        always_ff @(posedge clock)
            if (0 < rob_free && s == (int'(tail_q)) % ROB_DEPTH)
                    alloc[s] <= disp_rob[ROB_ALLOC_BITS-1:0];
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            head_q <= 0;
            tail_q <= 0;
            count_q <= 0;
            completed <= 0;
            store_started <= 0;
            store_responded <= 0;
        end else begin
            if (st_start_valid) store_started[head_q] <= 1;
            if (st_done_valid && count_q != 0 && store_started[head_q])
                store_responded[head_q] <= 1;
            for (int w = 0; w < WB_WIDTH; w = w + 1) begin
                if (done_valid[w] &&
                    (age(done_tag[w*TAG_BITS +: TAG_BITS], head_q) < count_q) &&
                    (!squash_valid ||
                     (age(done_tag[w*TAG_BITS +: TAG_BITS], head_q) < keep_count)))
                    completed[done_tag[w*TAG_BITS +: TAG_BITS]] <= 1;
            end
            if (disp_fire && !squash_valid) begin
                begin
                    if (0 < disp_count) begin
                        completed[(tail_q + 0) % ROB_DEPTH] <= 0;
                        store_started[(tail_q + 0) % ROB_DEPTH] <= 0;
                        store_responded[(tail_q + 0) % ROB_DEPTH] <= 0;
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
