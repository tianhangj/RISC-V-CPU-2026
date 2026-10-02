module pc_increment_test;
    reg [31:0] pc;
    wire [159:0] next_pc;
    reg [31:0] random_pc;
    for (genvar words = 0; words < 5; words = words+1) begin : g_case
        pc_increment #(.WORDS(words)) dut (
            .pc(pc), .next_pc(next_pc[words*32 +: 32]));
    end
    task automatic check(input [31:0] address);
        pc = address;
        #1;
        for (integer words = 0; words < 5; words = words+1)
            if (next_pc[words*32 +: 32] !== address + 32'(words*4))
                $fatal(1, "PC increment pc=%h words=%0d got=%h",
                       address, words, next_pc[words*32 +: 32]);
    endtask
    initial begin
        // Exhaust low bits on both sides of the 32-bit wrap boundary,
        // including unaligned values whose bottom bits must be preserved.
        for (integer low = 0; low < 8192; low = low+1) begin
            check(32'(low));
            check(32'hffffe000 | 32'(low));
        end
        for (integer bit_no = 2; bit_no < 32; bit_no = bit_no+1) begin
            check((32'd1 << bit_no)-4);
            check((32'd1 << bit_no)-8);
            check((32'd1 << bit_no)-12);
            check((32'd1 << bit_no)-16);
        end
        random_pc = 32'h81234567;
        for (integer sample = 0; sample < 2048; sample = sample+1) begin
            random_pc = {random_pc[30:0], random_pc[31] ^ random_pc[21] ^ random_pc[1] ^ random_pc[0]};
            check(random_pc);
        end
        $display("PASS PC increments 0..4 words, carry boundaries and wrap");
        $finish;
    end
endmodule
