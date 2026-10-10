module nibble_compare (
    input wire [3:0] a, b,
    output wire less, equal
);
    assign less=a<b;
    assign equal=a==b;
endmodule

module word_compare (
    input wire [31:0] a, b,
    output wire less, equal
);
    wire [7:0] group_less, group_equal, winning_less;
    for (genvar k=0; k<8; k=k+1) begin : g_group
        (* keep_hierarchy, keep *) nibble_compare compare_cell (
            .a(a[k*4 +: 4]), .b(b[k*4 +: 4]),
            .less(group_less[k]), .equal(group_equal[k]));
        if (k<7) assign winning_less[k]=group_less[k] & (&group_equal[7:k+1]);
        else assign winning_less[k]=group_less[k];
    end
    assign less=|winning_less;
    assign equal=&group_equal;
endmodule
