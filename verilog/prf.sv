module prf #(
    parameter integer BYPASS_WRITE = 0,
    parameter integer ISSUE_WIDTH = 2,
    parameter integer WB_WIDTH = 2,
    parameter integer FORWARD_WIDTH = WB_WIDTH,
    parameter integer PRF_SIZE = 64,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1
) (
    input logic clock, reset,
    input logic [2*ISSUE_WIDTH*PW-1:0] rd_addr,
    output logic [2*ISSUE_WIDTH*32-1:0] rd_data,
    input logic [WB_WIDTH-1:0] write_valid,
    input logic [WB_WIDTH*PW-1:0] write_pdst,
    input logic [WB_WIDTH*32-1:0] write_value,
    input logic [FORWARD_WIDTH-1:0] forward_valid,
    input logic [FORWARD_WIDTH*PW-1:0] forward_pdst,
    input logic [FORWARD_WIDTH*32-1:0] forward_value
);
    localparam integer BANK_COUNT = (PRF_SIZE + 7) / 8;
    logic [31:0] cells [0:PRF_SIZE-1];
    wire [BANK_COUNT*WB_WIDTH*32-1:0] bank_write_value;
    wire [PRF_SIZE*2-1:0] word_reset;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(WB_WIDTH*32), .BRANCHES(BANK_COUNT))
        distribute_write_value(write_value, bank_write_value);
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(PRF_SIZE*2))
        distribute_reset(reset, word_reset);
    for (genvar p = 0; p < 2*ISSUE_WIDTH; p = p + 1) begin : g_read
        wire [PW-1:0] addr = rd_addr[p*PW +: PW];
        wire [7:0] low_select;
        wire [BANK_COUNT*8-1:0] bank_low_select;
        wire [BANK_COUNT-1:0] high_select;
        logic [31:0] bank_data [0:BANK_COUNT-1];
        wire [31:0] masked_bank [0:BANK_COUNT-1];
        logic [31:0] read_value;
        (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(8), .BRANCHES(BANK_COUNT))
            distribute_low_select(low_select, bank_low_select);

        for (genvar low = 0; low < 8; low = low + 1) begin : g_low_decode
            localparam logic [2:0] LOW_INDEX = low;
            assign low_select[low] = (addr[2:0] == LOW_INDEX);
        end
        for (genvar bank = 0; bank < BANK_COUNT; bank = bank + 1) begin : g_bank
            localparam logic [PW-1:0] BANK_INDEX = bank;
            wire [31:0] word_data [0:7];
            wire [1:0] bank_enable;
            assign high_select[bank] = ((addr >> 3) == BANK_INDEX);
            (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(2))
                distribute_bank_enable(high_select[bank], bank_enable);
            for (genvar low = 0; low < 8; low = low + 1) begin : g_word
                localparam integer CELL_INDEX = 8*bank + low;
                if (CELL_INDEX == 0 || CELL_INDEX >= PRF_SIZE) begin : g_zero
                    assign word_data[low] = 32'b0;
                end else begin : g_cell
                    assign word_data[low] = cells[CELL_INDEX];
                end
            end
            always_comb begin
                bank_data[bank] = 32'b0;
                for (int low = 0; low < 8; low = low + 1)
                    bank_data[bank] = bank_data[bank] |
                                      (word_data[low] & {32{bank_low_select[bank*8+low]}});
            end
            for (genvar half = 0; half < 2; half = half+1) begin : g_mask_bank
                assign masked_bank[bank][half*16 +: 16] =
                    bank_data[bank][half*16 +: 16] & {16{bank_enable[half]}};
            end
        end
        always_comb begin
            read_value = 32'b0;
            for (int bank = 0; bank < BANK_COUNT; bank = bank + 1)
                read_value = read_value | masked_bank[bank];
        end
        reg [31:0] forwarded_value;
        always @* begin
            forwarded_value = read_value;
            if (BYPASS_WRITE != 0 && !reset)
                for (integer w = 0; w < FORWARD_WIDTH; w = w+1)
                    if (forward_valid[w] && forward_pdst[w*PW +: PW] == addr)
                        forwarded_value = forward_value[w*32 +: 32];
        end
        assign rd_data[p*32 +: 32] = (addr == 0) ? 32'b0 : forwarded_value;
    end
    for (genvar word_no = 1; word_no < PRF_SIZE; word_no = word_no+1) begin : g_write_word
        wire [WB_WIDTH*2-1:0] write_enable;
        for (genvar w = 0; w < WB_WIDTH; w = w+1) begin : g_write_port
            (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(2)) distribute_write_enable(
                write_valid[w] && write_pdst[w*PW +: PW] == PW'(word_no),
                write_enable[w*2 +: 2]);
        end
        for (genvar half = 0; half < 2; half = half+1) begin : g_half
            always_ff @(posedge clock) begin
                if (word_reset[word_no*2+half]) begin
                    if (word_no < 32) cells[word_no][half*16 +: 16] <= 0;
                end else
                    for (int w = 0; w < WB_WIDTH; w = w+1)
                        if (write_enable[w*2+half])
                            cells[word_no][half*16 +: 16] <=
                                bank_write_value[((word_no/8)*WB_WIDTH+w)*32+half*16 +: 16];
            end
        end
    end
endmodule
