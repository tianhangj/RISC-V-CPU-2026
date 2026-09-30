module prf #(
    parameter integer ISSUE_WIDTH = 2,
    parameter integer WB_WIDTH = 2,
    parameter integer PRF_SIZE = 64,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1
) (
    input logic clock, reset,
    input logic [2*ISSUE_WIDTH*PW-1:0] rd_addr,
    output logic [2*ISSUE_WIDTH*32-1:0] rd_data,
    input logic [WB_WIDTH-1:0] write_valid,
    input logic [WB_WIDTH*PW-1:0] write_pdst,
    input logic [WB_WIDTH*32-1:0] write_value
);
    localparam integer BANK_COUNT = (PRF_SIZE + 7) / 8;
    logic [31:0] cells [0:PRF_SIZE-1];
    for (genvar p = 0; p < 2*ISSUE_WIDTH; p = p + 1) begin : g_read
        wire [PW-1:0] addr = rd_addr[p*PW +: PW];
        wire [7:0] low_select;
        wire [BANK_COUNT-1:0] high_select;
        logic [31:0] bank_data [0:BANK_COUNT-1];
        wire [31:0] masked_bank [0:BANK_COUNT-1];
        logic [31:0] read_value;

        for (genvar low = 0; low < 8; low = low + 1) begin : g_low_decode
            localparam logic [2:0] LOW_INDEX = low;
            assign low_select[low] = (addr[2:0] == LOW_INDEX);
        end
        for (genvar bank = 0; bank < BANK_COUNT; bank = bank + 1) begin : g_bank
            localparam logic [PW-1:0] BANK_INDEX = bank;
            wire [31:0] word_data [0:7];
            assign high_select[bank] = ((addr >> 3) == BANK_INDEX);
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
                                      (word_data[low] & {32{low_select[low]}});
            end
            assign masked_bank[bank] = bank_data[bank] & {32{high_select[bank]}};
        end
        always_comb begin
            read_value = 32'b0;
            for (int bank = 0; bank < BANK_COUNT; bank = bank + 1)
                read_value = read_value | masked_bank[bank];
        end
        assign rd_data[p*32 +: 32] = (addr == 0) ? 32'b0 : read_value;
    end
    always_ff @(posedge clock) begin
        if (reset) begin
            for (int p = 1; p < 32; p = p + 1) cells[p] <= 0;
        end else begin
            for (int w = 0; w < WB_WIDTH; w = w + 1)
                if (write_valid[w] && write_pdst[w*PW +: PW] != 0)
                    cells[write_pdst[w*PW +: PW]] <= write_value[w*32 +: 32];
        end
    end
endmodule
