module word_adder (
    input wire [31:0] a, b,
    input wire carry_in,
    output wire [31:0] sum
);
    assign sum = a + b + {31'b0, carry_in};
endmodule
