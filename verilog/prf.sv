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
    logic [31:0] cells [0:PRF_SIZE-1];
    for (genvar p = 0; p < 2*ISSUE_WIDTH; p = p + 1) begin : g_read
        wire [PW-1:0] addr = rd_addr[p*PW +: PW];
        assign rd_data[p*32 +: 32] = (addr == 0) ? 32'b0 : cells[addr];
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
