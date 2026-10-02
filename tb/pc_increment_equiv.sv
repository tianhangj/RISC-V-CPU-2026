// Yosys SAT harness: prove all 32-bit addresses, including overflow.
module pc_increment_equiv (
    input wire [31:0] pc,
    output wire matched
);
    wire [4:0] equal;
    for (genvar words = 0; words < 5; words = words+1) begin : g_case
        wire [31:0] next_pc;
        pc_increment #(.WORDS(words)) dut (.pc(pc), .next_pc(next_pc));
        assign equal[words] = next_pc == pc + 32'(words*4);
    end
    assign matched = &equal;
endmodule
