// Combinational proof over all 32-bit inputs, including carry-in and wrap.
module word_adder_equiv (
    input wire [31:0] a, b,
    input wire carry_in,
    output wire ok
);
    wire [31:0] sum;
    word_adder dut (.a(a), .b(b), .carry_in(carry_in), .sum(sum));
    assign ok=(sum==(a+b+{31'b0,carry_in}));
endmodule
