module prf #(
    parameter integer WB_WIDTH = 2,
    parameter integer PRF_SIZE = 48
) (
    input logic clock, reset,
    input logic [2*PW-1:0] rd_addr,
    output logic [63:0] rd_data,
    input logic [WB_WIDTH-1:0] write_valid,
    input logic [WB_WIDTH*PW-1:0] write_pdst,
    input logic [WB_WIDTH*32-1:0] write_value
);
    localparam integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1;
    localparam integer BANK_COUNT = (PRF_SIZE + 7) / 8;
    logic [31:0] cells [0:PRF_SIZE-1];
    wire [BANK_COUNT*WB_WIDTH*32-1:0] bank_write_value;
    wire [PRF_SIZE*2-1:0] word_reset;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(WB_WIDTH*32), .BRANCHES(BANK_COUNT))
        distribute_write_value(write_value, bank_write_value);
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(PRF_SIZE*2))
        distribute_reset(reset, word_reset);
    for (genvar p = 0; p < 2; p = p + 1) begin : g_read
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
        assign rd_data[p*32 +: 32] = (addr == 0) ? 32'b0 : read_value;
    end
    begin : g_word_ram
        reg [WB_WIDTH-1:0] last_valid;
        reg [WB_WIDTH*PW-1:0] last_pdst;
        reg [WB_WIDTH*32-1:0] last_value;
        reg last_reset;
        wire [PRF_SIZE-1:0] previous_reset;
        (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(PRF_SIZE))
            distribute_previous_reset(last_reset,previous_reset);
        always @(posedge clock) begin
            last_reset<=reset;
            last_valid<=reset?0:write_valid;
            last_pdst<=write_pdst; last_value<=write_value;
        end
        for (genvar word_no=1; word_no<PRF_SIZE; word_no=word_no+1) begin : g_word
            wire [31:0] ram_data;
            reg [31:0] write_data, read_data;
            reg write_word;
            always @* begin
                write_word=0; write_data=bank_write_value[(word_no/8)*WB_WIDTH*32 +: 32]; read_data=ram_data;
                for (integer w=0; w<WB_WIDTH; w=w+1) begin
                    if (write_valid[w] && write_pdst[w*PW +: PW]==PW'(word_no)) begin
                        write_word=1;
                        if (w>0) write_data=bank_write_value[((word_no/8)*WB_WIDTH+w)*32 +: 32];
                    end
                    if (last_valid[w] && last_pdst[w*PW +: PW]==PW'(word_no))
                        read_data=last_value[w*32 +: 32];
                end
                if (previous_reset[word_no] && word_no<32) read_data=0;
            end
            sram_fakeram #(.DEPTH(1), .WIDTH(32)) word (
                .clk(clock), .en(1'b1), .we(word_reset[2*word_no]?(word_no<32):write_word),
                .wmask(1'b1), .addr(1'b0), .wdata(word_reset[2*word_no]?32'b0:write_data), .rdata(ram_data));
            assign cells[word_no]=read_data;
        end
    end
endmodule
