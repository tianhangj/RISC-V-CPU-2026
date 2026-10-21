module prf #(
    parameter integer READ_PORTS = 2,
    parameter integer WB_WIDTH = 2,
    parameter integer PRF_SIZE = 48
) (
    input logic clock, reset,
    input logic [READ_PORTS*PW-1:0] rd_addr,
    output logic [READ_PORTS*32-1:0] rd_data,
    input logic [WB_WIDTH-1:0] write_valid,
    input logic [WB_WIDTH*PW-1:0] write_pdst,
    input logic [WB_WIDTH*32-1:0] write_value
);
    localparam integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1;
    localparam integer BANK_COUNT = (PRF_SIZE + 7) / 8;
    logic [31:0] cells [0:PRF_SIZE-1];
    assign cells[0]=32'b0;
    wire [BANK_COUNT*WB_WIDTH*32-1:0] bank_write_value;
    wire [WB_WIDTH*8-1:0] write_low_select;
    wire [BANK_COUNT*WB_WIDTH*8-1:0] bank_word_select;
    reg [WB_WIDTH-1:0] last_valid;
    reg [WB_WIDTH*PW-1:0] last_pdst;
    reg [WB_WIDTH*32-1:0] last_value;
    reg last_reset;
    always @(posedge clock) begin
        last_reset<=reset;
        last_valid<=reset?0:write_valid;
        last_pdst<=write_pdst; last_value<=write_value;
    end
    for (genvar w=0; w<WB_WIDTH; w=w+1) begin : g_write_decode
        for (genvar low=0; low<8; low=low+1) begin : g_low
            assign write_low_select[w*8+low] = write_pdst[w*PW +: 3]==3'(low);
        end
        for (genvar bank=0; bank<BANK_COUNT; bank=bank+1) begin : g_bank
            wire bank_enable = write_valid[w] && (write_pdst[w*PW +: PW] >> 3)==PW'(bank);
            assign bank_word_select[(bank*WB_WIDTH+w)*8 +: 8] =
                write_low_select[w*8 +: 8] & {8{bank_enable}};
        end
    end
    wire [PRF_SIZE*2-1:0] word_reset;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(WB_WIDTH*32), .BRANCHES(BANK_COUNT))
        distribute_write_value(write_value, bank_write_value);
    (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(PRF_SIZE*2))
        distribute_reset(reset, word_reset);
    for (genvar p = 0; p < READ_PORTS; p = p + 1) begin : g_read
        wire [PW-1:0] addr = rd_addr[p*PW +: PW];
        wire [31:0] read_value = addr<PRF_SIZE ? cells[addr] : 32'b0;
        wire [WB_WIDTH*2-1:0] previous_select;
        wire [1:0] read_zero;
        reg [31:0] bypassed_value;
        for (genvar w=0; w<WB_WIDTH; w=w+1) begin : g_previous
            (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(2)) distribute(
                last_valid[w] && last_pdst[w*PW +: PW]==addr,
                previous_select[w*2 +: 2]);
        end
        (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(2)) distribute_zero(
            addr==0 || (last_reset && addr<32),read_zero);
        always @* begin
            bypassed_value=read_value;
            for (integer w=0; w<WB_WIDTH; w=w+1)
                for (integer half=0; half<2; half=half+1)
                    if (previous_select[w*2+half])
                        bypassed_value[half*16 +: 16]=last_value[w*32+half*16 +: 16];
            // The registered WB packet is readable before its PRF write edge.
            for (integer w=0; w<WB_WIDTH; w=w+1)
                if (write_valid[w] && write_pdst[w*PW +: PW]==addr)
                    bypassed_value=write_value[w*32 +: 32];
            for (integer half=0; half<2; half=half+1)
                if (read_zero[half]) bypassed_value[half*16 +: 16]=0;
        end
        assign rd_data[p*32 +: 32]=bypassed_value;
    end
    begin : g_word_ram
        for (genvar word_no=1; word_no<PRF_SIZE; word_no=word_no+1) begin : g_word
            wire [31:0] ram_data;
            reg [31:0] write_data;
            reg write_word;
            always @* begin
                write_word=0; write_data=bank_write_value[(word_no/8)*WB_WIDTH*32 +: 32];
                for (integer w=0; w<WB_WIDTH; w=w+1) begin
                    if (bank_word_select[((word_no/8)*WB_WIDTH+w)*8+word_no%8]) begin
                        write_word=1;
                        if (w>0) write_data=bank_write_value[((word_no/8)*WB_WIDTH+w)*32 +: 32];
                    end
                end
            end
            sram_fakeram #(.DEPTH(1), .WIDTH(32)) word (
                .clk(clock), .en(1'b1), .we(word_reset[2*word_no]?(word_no<32):write_word),
                .wmask(1'b1), .addr(1'b0), .wdata(word_reset[2*word_no]?32'b0:write_data), .rdata(ram_data));
            assign cells[word_no]=ram_data;
        end
    end
endmodule
