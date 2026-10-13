// Always-read SRAM words with one bypass after each selected read. Queue
// ownership/validity stays with the caller; no payload reset is required.
module payload_ram #(
    parameter integer DEPTH = 16,
    parameter integer WIDTH = 32,
    parameter integer READ_PORTS = 1
) (
    input wire clock, reset,
    input wire write_valid,
    input wire [IW-1:0] write_addr,
    input wire [WIDTH-1:0] write_data,
    input wire [READ_PORTS*IW-1:0] read_addr,
    output wire [READ_PORTS*WIDTH-1:0] read_data
);
    localparam integer IW=(DEPTH>1)?$clog2(DEPTH):1;
    localparam integer GROUPS=(WIDTH+15)/16;
    localparam integer WRITE_BRANCHES=(DEPTH+1)/2;
    wire [DEPTH*WIDTH-1:0] words;
    wire [WRITE_BRANCHES*WIDTH-1:0] distributed_data;
    reg last_valid;
    reg [IW-1:0] last_addr;
    reg [WIDTH-1:0] last_data;
    always @(posedge clock) begin
        if (reset) last_valid<=0;
        else last_valid<=write_valid;
        if (write_valid) begin last_addr<=write_addr; last_data<=write_data; end
    end
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(WIDTH), .BRANCHES(WRITE_BRANCHES))
        distribute_write(write_data,distributed_data);
    for (genvar slot=0; slot<DEPTH; slot=slot+1) begin : g_word
        sram_fakeram #(.DEPTH(1), .WIDTH(WIDTH)) word (
            .clk(clock), .en(1'b1), .we(!reset && write_valid && write_addr==IW'(slot)),
            .wmask(1'b1), .addr(1'b0), .wdata(distributed_data[(slot/2)*WIDTH +: WIDTH]),
            .rdata(words[slot*WIDTH +: WIDTH]));
    end
    for (genvar port=0; port<READ_PORTS; port=port+1) begin : g_read
        wire [IW-1:0] addr=read_addr[port*IW +: IW];
        wire [DEPTH*GROUPS-1:0] select_word;
        wire [GROUPS-1:0] select_last;
        reg [WIDTH-1:0] selected;
        for (genvar slot=0; slot<DEPTH; slot=slot+1) begin : g_select
            (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(GROUPS)) distribute(
                addr==IW'(slot),select_word[slot*GROUPS +: GROUPS]);
        end
        (* keep_hierarchy, keep *) signal_fanout #(.BRANCHES(GROUPS)) distribute_last(
            last_valid && addr==last_addr,select_last);
        always @* begin
            selected=0;
            for (integer slot=0; slot<DEPTH; slot=slot+1)
                for (integer bit_no=0; bit_no<WIDTH; bit_no=bit_no+1)
                    selected[bit_no]=selected[bit_no] |
                        (words[slot*WIDTH+bit_no] & select_word[slot*GROUPS+bit_no/16]);
        end
        for (genvar chunk=0; chunk<GROUPS; chunk=chunk+1) begin : g_bypass
            localparam integer BASE=16*chunk;
            localparam integer BITS=(WIDTH-BASE>16)?16:WIDTH-BASE;
            assign read_data[port*WIDTH+BASE +: BITS]=select_last[chunk]?
                last_data[BASE +: BITS]:selected[BASE +: BITS];
        end
    end
endmodule
