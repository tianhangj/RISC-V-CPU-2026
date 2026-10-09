module alu_forwarding_test;
    wire resolve_exec_valid=1'b0;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1, squash_valid = 0, exec_valid = 0, result_ready = 1;
    logic [4:0] squash_tag = 0, rob_head = 5'd30;
    logic [146:0] exec_payload = 0;
    wire exec_ready, result_valid, resolve_valid;
    wire [42:0] result_payload;
    wire [104:0] resolve_payload;
    alu #(.PIPELINED(0)) dut (.*);

    task automatic send(input [4:0] tag, input [5:0] op,
                        input [31:0] a, b, imm);
        exec_valid = 1;
        exec_payload = {tag, 2'd0, op, 6'd32, 32'd100, imm, a, b};
        #1;
    endtask
    task automatic expect_result(input [4:0] tag, input [31:0] value);
        if (!result_valid || result_payload !== {tag, 6'd32, value})
            $fatal(1, "ALU forwarding lost result tag=%0d value=%h", tag, value);
    endtask

    initial begin
        repeat (2) @(negedge clock);
        reset = 0;
        // Independent operations must complete every cycle without a result bubble.
        for (integer n = 0; n < 8; n = n+1) begin
            send(5'(30+n), 6'd20, 32'(n), 32'd7, 0);
            expect_result(5'(30+n), 32'(n+7));
            if (!exec_ready) $fatal(1, "ALU forwarding stalled a ready WB");
            @(negedge clock);
        end
        exec_valid = 0;
        #1;
        if (result_valid) $fatal(1, "ALU forwarding duplicated an accepted result");

        // Branch resolution survives even when the link result was already accepted.
        send(5'd6, 6'd3, 0, 0, 40);
        expect_result(5'd6, 104);
        @(negedge clock) exec_valid = 0;
        #1;
        if (result_valid || !resolve_valid || resolve_payload !==
            {5'd6, 2'd0, 32'd100, 1'b0, 1'b1, 32'd140, 32'd140})
            $fatal(1, "early branch WB lost its registered resolution");
        @(negedge clock);
        if (resolve_valid) $fatal(1, "branch resolution repeated");

        // Capture a stalled result, then consume it while accepting its successor.
        result_ready = 0;
        send(5'd7, 6'd20, 9, 10, 0);
        expect_result(5'd7, 19);
        @(negedge clock);
        send(5'd8, 6'd20, 20, 1, 0);
        repeat (3) begin
            expect_result(5'd7, 19);
            if (exec_ready) $fatal(1, "blocked skid register accepted a successor");
            @(negedge clock);
        end
        result_ready = 1;
        #1;
        expect_result(5'd7, 19);
        if (!exec_ready) $fatal(1, "draining skid register did not accept replacement");
        @(negedge clock) exec_valid = 0;
        #1;
        expect_result(5'd8, 21);
        @(negedge clock);
        if (result_valid) $fatal(1, "skid replacement duplicated a result");

        // Age comparisons must work across ROB wrap for direct and held results.
        result_ready = 0;
        send(5'd1, 6'd20, 2, 3, 0);
        @(negedge clock) exec_valid = 0;
        squash_valid = 1;
        squash_tag = 31;
        @(negedge clock);
        if (result_valid) $fatal(1, "squash retained a young skid result");
        result_ready = 1;
        send(5'd2, 6'd3, 0, 0, 4);
        if (result_valid) $fatal(1, "squash published a young direct result");
        @(negedge clock);
        send(5'd30, 6'd20, 4, 5, 0);
        if (resolve_valid) $fatal(1, "squash published a young resolution");
        expect_result(5'd30, 9);
        @(negedge clock) exec_valid = 0;
        $display("PASS ALU forwarding, skid replacement, branch resolution and ROB wrap");
        $finish;
    end
    initial begin
        #2000;
        $fatal(1, "ALU forwarding timeout");
    end
endmodule
