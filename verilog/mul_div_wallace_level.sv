module mul_div_wallace_level #(
    parameter integer N = 34,
    parameter integer M = 2 * (N / 3) + (N % 3)
) (
    input wire [N*64-1:0] in_terms,
    output wire [M*64-1:0] out_terms
);
    for (genvar i = 0; i < N/3; i = i + 1) begin : g_compress
        wire [63:0] x = in_terms[(3*i)*64 +: 64];
        wire [63:0] y = in_terms[(3*i+1)*64 +: 64];
        wire [63:0] z = in_terms[(3*i+2)*64 +: 64];
        assign out_terms[(2*i)*64 +: 64] = x ^ y ^ z;
        assign out_terms[(2*i+1)*64 +: 64] = ((x & y) | (x & z) | (y & z)) << 1;
    end
    for (genvar i = 0; i < N%3; i = i + 1) begin : g_passthrough
        assign out_terms[(2*(N/3)+i)*64 +: 64] =
            in_terms[(3*(N/3)+i)*64 +: 64];
    end
endmodule
