// Constant word increments use parallel carry reductions. Keeping this small
// boundary prevents shared predictor/queue loads from turning the increment
// into a long ripple path during mapping.
module pc_increment #(parameter integer WORDS = 1) (
    input wire [31:0] pc,
    output wire [31:0] next_pc
);
    localparam integer LOW_W = (WORDS > 0) ? $clog2(WORDS+1) : 1;
    generate if (WORDS == 0) begin : g_identity
        assign next_pc = pc;
    end else begin : g_increment
        wire [LOW_W:0] low_sum = {1'b0, pc[2 +: LOW_W]} + (LOW_W+1)'(WORDS);
        assign next_pc[1:0] = pc[1:0];
        assign next_pc[2 +: LOW_W] = low_sum[LOW_W-1:0];
        for (genvar bit_no = LOW_W+2; bit_no < 32; bit_no = bit_no+1) begin : g_carry
            if (bit_no == LOW_W+2)
                assign next_pc[bit_no] = pc[bit_no] ^ low_sum[LOW_W];
            else
                assign next_pc[bit_no] = pc[bit_no] ^
                    (low_sum[LOW_W] && (&pc[bit_no-1:LOW_W+2]));
        end
    end endgenerate
endmodule
