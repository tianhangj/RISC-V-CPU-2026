module word_compare (
    input wire [31:0] a, b,
    output wire less, equal
);
    assign less = a < b;
    assign equal = a == b;
endmodule
