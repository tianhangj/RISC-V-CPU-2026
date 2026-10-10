// Four-bit groups bound local carry depth; a parallel prefix computes the
// carry between groups. Retained group boundaries prevent a 32-bit ripple
// chain from being reconstructed by the area-oriented technology mapper.
module nibble_adder (
    input wire [3:0] a, b,
    input wire carry_in,
    output wire [3:0] sum,
    output wire propagate, generate_carry
);
    wire [4:0] base_sum={1'b0,a}+{1'b0,b};
    assign generate_carry=base_sum[4];
    assign propagate=&(a^b);
    assign sum=a+b+{3'b0,carry_in};
endmodule

module word_adder (
    input wire [31:0] a, b,
    input wire carry_in,
    output wire [31:0] sum
);
    wire [7:0] p [0:3], g [0:3];
    wire [7:0] carry;
    assign carry[0]=carry_in;
    for (genvar k=0; k<8; k=k+1) begin : g_nibble
        (* keep_hierarchy, keep *) nibble_adder group_cell (
            .a(a[k*4 +: 4]), .b(b[k*4 +: 4]), .carry_in(carry[k]),
            .sum(sum[k*4 +: 4]), .propagate(p[0][k]), .generate_carry(g[0][k]));
        if (k>0) assign carry[k]=g[3][k-1] | (p[3][k-1]&carry_in);
    end
    for (genvar level=0; level<3; level=level+1) begin : g_prefix
        for (genvar k=0; k<8; k=k+1) begin : g_bit
            if (k >= (1<<level)) begin
                assign p[level+1][k]=p[level][k]&p[level][k-(1<<level)];
                assign g[level+1][k]=g[level][k] |
                    (p[level][k]&g[level][k-(1<<level)]);
            end else begin
                assign p[level+1][k]=p[level][k];
                assign g[level+1][k]=g[level][k];
            end
        end
    end
endmodule
