module wb_arb #(
    parameter integer WB_WIDTH = 2,
    parameter integer EXTRA_ALU = 0,
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 48
) (
    input logic clock, reset,
    input logic squash_valid,
    input logic [TAG_BITS-1:0] squash_tag,
    input logic [RW-1:0] rob_head,
    input logic alu_result_valid,
    output logic alu_result_ready,
    input logic [RESULT_BITS-1:0] alu_result_payload,
    input wire alu2_result_valid,
    output wire alu2_result_ready,
    input wire [RESULT_BITS-1:0] alu2_result_payload,
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
    localparam integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1;
    localparam integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1;
    localparam integer FU_SRC_COUNT = 3+EXTRA_ALU;
    localparam integer TAG_BITS = RW;
    localparam integer RESULT_BITS = TAG_BITS + PW + 32;
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
    localparam integer DATA_GROUPS=(RESULT_BITS+15)/16;
    reg [WB_WIDTH*FU_SRC_COUNT-1:0] lane_choice;
    wire [WB_WIDTH*FU_SRC_COUNT*DATA_GROUPS-1:0] data_choice;
    for (genvar lane=0; lane<WB_WIDTH; lane=lane+1) begin : g_lane_data
        wire [RESULT_BITS-1:0] words [0:FU_SRC_COUNT-1];
        reg [RESULT_BITS-1:0] data;
        for (genvar src=0; src<FU_SRC_COUNT; src=src+1) begin : g_source
            localparam integer BASE=(lane*FU_SRC_COUNT+src)*DATA_GROUPS;
            (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(DATA_GROUPS)) distribute(
                lane_choice[lane*FU_SRC_COUNT+src],data_choice[BASE +: DATA_GROUPS]);
            for (genvar chunk=0; chunk<DATA_GROUPS; chunk=chunk+1) begin : g_chunk
                localparam integer FIRST=16*chunk;
                localparam integer BITS=(RESULT_BITS-FIRST>16)?16:RESULT_BITS-FIRST;
                assign words[src][FIRST +: BITS]=source_payload[src][FIRST +: BITS] &
                    {BITS{data_choice[BASE+chunk]}};
            end
        end
        always @* begin
            data=0;
            for (integer src=0; src<FU_SRC_COUNT; src=src+1) data=data | words[src];
        end
        assign selected_done_tag[lane*TAG_BITS +: TAG_BITS]=data[RESULT_BITS-1 -: TAG_BITS];
        assign selected_write_pdst[lane*PW +: PW]=data[32 +: PW];
        assign selected_write_value[lane*32 +: 32]=data[31:0];
    end
    always_comb begin
        begin
            source_valid[0] = alu_result_valid;
            source_payload[0] = alu_result_payload[RESULT_BITS-1:0];
        end
        source_valid[1] = mul_result_valid;
        source_payload[1] = mul_result_payload;
        source_valid[2] = lsu_result_valid;
        source_payload[2] = lsu_result_payload;
        if (EXTRA_ALU!=0) begin
            source_valid[3]=alu2_result_valid;
            source_payload[3]=alu2_result_payload;
        end
        for (int i = 0; i < FU_SRC_COUNT; i = i + 1)
            discard[i] = source_valid[i] && squash_valid &&
                ((source_payload[i][RESULT_BITS-1 -: TAG_BITS] - rob_head) > (squash_tag - rob_head));
        source_ready = 0;
        selected = 0;
        selected_done_valid = 0;
        selected_write_valid = 0;
        lane_choice=0;
        next_cursor = cursor;
        for (int lane = 0; lane < WB_WIDTH; lane = lane + 1) begin
            chosen = WB_WIDTH>=2 &&
                lane==0 && source_valid[0] ? 0 : -1;
            for (int offset = 0; offset < FU_SRC_COUNT; offset = offset + 1) begin
                // cursor and offset are each below FU_SRC_COUNT; one subtraction wraps.
                candidate = int'(next_cursor) + offset;
                if (candidate >= FU_SRC_COUNT) candidate = candidate - FU_SRC_COUNT;
                if (chosen < 0 && source_valid[candidate] &&
                    !selected[candidate])
                    chosen = candidate;
            end
            if (chosen >= 0) begin
                selected[chosen] = 1;
                lane_choice[lane*FU_SRC_COUNT+chosen]=1;
                source_ready[chosen] = 1;
                selected_done_valid[lane] = !discard[chosen];
                selected_write_valid[lane] = !discard[chosen] &&
                    (source_payload[chosen][32 +: PW] != 0);
                next_cursor = (chosen == FU_SRC_COUNT-1) ? 0 : CURSOR_BITS'(chosen + 1);
            end
        end
        alu_result_ready = WB_WIDTH>=2 ? 1'b1 : source_ready[0];
        mul_result_ready = source_ready[1];
        lsu_result_ready = source_ready[2];
    end
    assign alu2_result_ready=EXTRA_ALU!=0 ? source_ready[FU_SRC_COUNT-1] : 1'b0;
    always_ff @(posedge clock) begin
        if (reset) cursor <= 0;
        else cursor <= next_cursor;
    end
    generate
        begin : g_direct
            assign done_valid = selected_done_valid;
            assign done_tag = selected_done_tag;
            assign write_valid = selected_write_valid;
            assign write_pdst = selected_write_pdst;
            assign write_value = selected_write_value;
        end
    endgenerate

endmodule
