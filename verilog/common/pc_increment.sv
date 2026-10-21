module pc_increment #(
    parameter integer WORDS = 1
) (
    input wire [31:0] pc,
    output wire [31:0] next_pc
);
    assign next_pc = pc + 32'(4 * WORDS);
endmodule
