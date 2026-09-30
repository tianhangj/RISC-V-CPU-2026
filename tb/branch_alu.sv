module branch_alu_test;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1;
    logic squash_valid = 0;
    logic [4:0] squash_tag = 0, rob_head = 0;
    logic exec_valid = 0;
    wire exec_ready, result_valid, resolve_valid;
    logic result_ready = 0;
    logic [146:0] exec_payload = 0;
    wire [42:0] result_payload;
    wire [104:0] resolve_payload;
    alu dut (.*);
    task automatic run(input [5:0] op, input [31:0] a, input [31:0] b,
                       input [31:0] imm, input logic taken, input [31:0] target);
        @(negedge clock);
        exec_valid = 1;
        exec_payload = {5'd2, 2'd1, op, 6'd33, 32'd100, imm, a, b};
        @(negedge clock);
        exec_valid = 0;
        if (!resolve_valid || resolve_payload !==
            {5'd2, 2'd1, 32'd100, (op >= 5 && op <= 10), taken, target,
             (taken ? target : 32'd104)})
            $fatal(1, "ALU resolution metadata op=%0d payload=%h", op, resolve_payload);
        if ((op == 3 || op == 4) && result_payload[31:0] !== 104)
            $fatal(1, "jump link result incorrect");
        repeat (3) begin
            @(negedge clock);
            if (resolve_valid || !result_valid) $fatal(1, "WB stall repeated/lost resolve");
        end
        result_ready = 1;
        @(negedge clock) result_ready = 0;
    endtask
    initial begin
        repeat (2) @(negedge clock);
        reset = 0;
        run(5, 1, 1, 4, 1, 104); // taken and fall-through have identical npc
        run(5, 1, 2, 40, 0, 140);
        run(6, 1, 2, 40, 1, 140);
        run(7, 32'hffffffff, 0, 40, 1, 140);
        run(8, 32'hffffffff, 0, 40, 0, 140);
        run(9, 32'hffffffff, 0, 40, 0, 140);
        run(10, 32'hffffffff, 0, 40, 1, 140);
        run(3, 0, 0, 32'hfffffffc, 1, 96);
        run(4, 200, 0, 5, 1, 204);
        $display("PASS ALU branch metadata and one-shot resolution under WB stall");
        $finish;
    end
    initial begin
        #10000;
        $fatal(1, "ALU branch timeout");
    end
endmodule
