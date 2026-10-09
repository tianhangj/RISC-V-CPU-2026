module word_compare_equiv (
    input wire [31:0] a, b,
    output wire ok
);
    wire less, equal;
    word_compare dut (.a(a), .b(b), .less(less), .equal(equal));
    assign ok=(less==(a<b)) && (equal==(a==b));
endmodule
