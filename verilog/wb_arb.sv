module wb_arb #(
    parameter integer PIPELINED = 0,
    parameter integer FILTER_AFTER_SELECT = 0,
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
    input logic clock, reset,
    input logic squash_valid,
    input logic [TAG_BITS-1:0] squash_tag,
    input logic [RW-1:0] rob_head,
    input logic [ISSUE_WIDTH-1:0] alu_result_valid,
    output logic [ISSUE_WIDTH-1:0] alu_result_ready,
    input logic [ISSUE_WIDTH*RESULT_BITS-1:0] alu_result_payload,
    input logic mul_result_valid,
    output logic mul_result_ready,
    input logic [RESULT_BITS-1:0] mul_result_payload,
    input logic lsu_result_valid,
    output logic lsu_result_ready,
    input logic [RESULT_BITS-1:0] lsu_result_payload,
    output logic [WB_WIDTH-1:0] done_valid,
    output logic [WB_WIDTH*TAG_BITS-1:0] done_tag,
    output logic [WB_WIDTH-1:0] write_valid,
    output logic [WB_WIDTH*PW-1:0] write_pdst,
    output logic [WB_WIDTH*32-1:0] write_value
);
    logic [WB_WIDTH-1:0] selected_done_valid, selected_write_valid;
    logic [WB_WIDTH*TAG_BITS-1:0] selected_done_tag;
    logic [WB_WIDTH*PW-1:0] selected_write_pdst;
    logic [WB_WIDTH*32-1:0] selected_write_value;
    logic [FU_SRC_COUNT-1:0] source_valid, source_ready, selected;
    logic [RESULT_BITS-1:0] source_payload [0:FU_SRC_COUNT-1];
    logic [FU_SRC_COUNT-1:0] discard;
    localparam integer CURSOR_BITS = (FU_SRC_COUNT > 1) ? $clog2(FU_SRC_COUNT) : 1;
    logic [CURSOR_BITS-1:0] cursor, next_cursor;
    integer candidate, chosen;
    always_comb begin
        for (int i = 0; i < ISSUE_WIDTH; i = i + 1) begin
            source_valid[i] = alu_result_valid[i];
            source_payload[i] = alu_result_payload[i*RESULT_BITS +: RESULT_BITS];
        end
        source_valid[ISSUE_WIDTH] = mul_result_valid;
        source_payload[ISSUE_WIDTH] = mul_result_payload;
        source_valid[ISSUE_WIDTH+1] = lsu_result_valid;
        source_payload[ISSUE_WIDTH+1] = lsu_result_payload;
        for (int i = 0; i < FU_SRC_COUNT; i = i + 1)
            discard[i] = source_valid[i] && squash_valid &&
                ((source_payload[i][RESULT_BITS-1 -: TAG_BITS] - rob_head) > (squash_tag - rob_head));
        source_ready = (FILTER_AFTER_SELECT != 0) ? 0 : discard;
        selected = 0;
        selected_done_valid = 0;
        selected_done_tag = 0;
        selected_write_valid = 0;
        selected_write_pdst = 0;
        selected_write_value = 0;
        next_cursor = cursor;
        for (int lane = 0; lane < WB_WIDTH; lane = lane + 1) begin
            chosen = -1;
            for (int offset = 0; offset < FU_SRC_COUNT; offset = offset + 1) begin
                // cursor and offset are each below FU_SRC_COUNT; one subtraction wraps.
                candidate = int'(next_cursor) + offset;
                if (candidate >= FU_SRC_COUNT) candidate = candidate - FU_SRC_COUNT;
                if (chosen < 0 && source_valid[candidate] &&
                    ((FILTER_AFTER_SELECT != 0) || !discard[candidate]) && !selected[candidate])
                    chosen = candidate;
            end
            if (chosen >= 0) begin
                selected[chosen] = 1;
                source_ready[chosen] = 1;
                selected_done_valid[lane] = !discard[chosen];
                selected_done_tag[lane*TAG_BITS +: TAG_BITS] = source_payload[chosen][RESULT_BITS-1 -: TAG_BITS];
                selected_write_pdst[lane*PW +: PW] = source_payload[chosen][32 +: PW];
                selected_write_value[lane*32 +: 32] = source_payload[chosen][31:0];
                selected_write_valid[lane] = !discard[chosen] &&
                    (source_payload[chosen][32 +: PW] != 0);
                next_cursor = (chosen == FU_SRC_COUNT-1) ? 0 : CURSOR_BITS'(chosen + 1);
            end
        end
        for (int i = 0; i < ISSUE_WIDTH; i = i + 1) alu_result_ready[i] = source_ready[i];
        mul_result_ready = source_ready[ISSUE_WIDTH];
        lsu_result_ready = source_ready[ISSUE_WIDTH+1];
    end
    always_ff @(posedge clock) begin
        if (reset) cursor <= 0;
        else cursor <= next_cursor;
    end
    generate
        if (PIPELINED == 0) begin : g_direct
            assign done_valid = selected_done_valid;
            assign done_tag = selected_done_tag;
            assign write_valid = selected_write_valid;
            assign write_pdst = selected_write_pdst;
            assign write_value = selected_write_value;
        end else begin : g_pipeline
            logic [WB_WIDTH-1:0] valid_q;
            logic [WB_WIDTH*TAG_BITS-1:0] tag_q;
            logic [WB_WIDTH*PW-1:0] pdst_q;
            logic [WB_WIDTH*32-1:0] value_q;
            always_ff @(posedge clock) begin
                if (reset) valid_q <= 0;
                else valid_q <= selected_done_valid;
                tag_q <= selected_done_tag;
                pdst_q <= selected_write_pdst;
                value_q <= selected_write_value;
            end
            assign done_tag = tag_q;
            assign write_pdst = pdst_q;
            assign write_value = value_q;
            for (genvar lane = 0; lane < WB_WIDTH; lane = lane+1) begin : g_lane
                wire [TAG_BITS-1:0] tag = tag_q[lane*TAG_BITS +: TAG_BITS];
                // A branch may resolve while a result waits in this stage.
                // Apply the age boundary again before publishing completion.
                assign done_valid[lane] = valid_q[lane] &&
                    (!squash_valid || ((tag-rob_head) <= (squash_tag-rob_head)));
                assign write_valid[lane] = done_valid[lane] &&
                    pdst_q[lane*PW +: PW] != 0;
            end
        end
    endgenerate

endmodule
