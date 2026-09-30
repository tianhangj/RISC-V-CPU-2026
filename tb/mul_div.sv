module mul_div_test;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1;
    logic squash_valid = 0;
    logic [4:0] squash_tag = 0;
    logic [4:0] rob_head = 0;
    logic exec_valid = 0;
    logic [77:0] exec_payload = 0;
    logic result_ready = 0;
    wire exec_ready, result_valid;
    wire [42:0] result_payload;
    integer checked = 0;

    mul_div dut (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .exec_valid, .exec_ready, .exec_payload,
        .result_valid, .result_ready, .result_payload
    );

    function automatic [31:0] golden(input [2:0] op,
                                      input [31:0] a, b);
        reg [63:0] uu;
        reg signed [63:0] sa, sb, ub, ss, su;
        begin
            sa = $signed(a);
            sb = $signed(b);
            ub = {32'b0, b};
            uu = {32'b0, a} * {32'b0, b};
            ss = sa * sb;
            su = sa * ub;
            case (op)
                0: golden = uu[31:0];
                1: golden = ss[63:32];
                2: golden = su[63:32];
                3: golden = uu[63:32];
                4: begin
                    if (b == 0) golden = 32'hffffffff;
                    else if (a == 32'h80000000 && b == 32'hffffffff) golden = a;
                    else golden = $signed(a) / $signed(b);
                end
                5: golden = b == 0 ? 32'hffffffff : a / b;
                6: begin
                    if (b == 0) golden = a;
                    else if (a == 32'h80000000 && b == 32'hffffffff) golden = 0;
                    else golden = $signed(a) % $signed(b);
                end
                7: golden = b == 0 ? a : a % b;
            endcase
        end
    endfunction

    task automatic expect_result(input [4:0] tag,
                                 input [5:0] pdst,
                                 input [31:0] value);
        if (!result_valid || result_payload !== {tag, pdst, value})
            $fatal(1, "result mismatch: got valid=%b payload=%h expected=%h",
                   result_valid, result_payload, {tag, pdst, value});
    endtask

    task automatic run_case(input [2:0] op, input [31:0] a, b);
        integer latency;
        reg [31:0] expected_value;
        begin
            expected_value = golden(op, a, b);
            latency = (op < 4) ? 0 :
                ((b == 0 || ((op == 4 || op == 6) &&
                 a == 32'h80000000 && b == 32'hffffffff)) ? 0 : 32);
            @(negedge clock);
            if (!exec_ready) $fatal(1, "unit failed to become ready");
            exec_payload = {5'd7, op, 6'd35, a, b};
            exec_valid = 1;
            result_ready = 0;
            @(posedge clock);
            #1;
            exec_valid = 0;
            if (latency == 0) expect_result(5'd7, 6'd35, expected_value);
            else if (result_valid) $fatal(1, "early result for op %d", op);
            for (integer cycle = 1; cycle <= latency; cycle = cycle + 1) begin
                @(posedge clock);
                #1;
                if (cycle == latency) expect_result(5'd7, 6'd35, expected_value);
                else if (result_valid)
                    $fatal(1, "early result op=%d cycle=%d", op, cycle);
                if (cycle < latency && exec_ready)
                    $fatal(1, "unit accepted another request while busy");
            end
            repeat (2) begin
                @(posedge clock);
                #1;
                expect_result(5'd7, 6'd35, expected_value);
                if (exec_ready) $fatal(1, "result backpressure ignored");
            end
            @(negedge clock);
            result_ready = 1;
            @(posedge clock);
            #1;
            result_ready = 0;
            if (result_valid || !exec_ready)
                $fatal(1, "result was not consumed");
            checked = checked + 1;
        end
    endtask

    reg [31:0] edges [0:5];
    reg [31:0] a, b;
    initial begin
        edges[0] = 0;
        edges[1] = 1;
        edges[2] = 32'hffffffff;
        edges[3] = 32'h80000000;
        edges[4] = 32'h7fffffff;
        edges[5] = 32'h80000001;
        repeat (3) @(posedge clock);
        @(negedge clock) reset = 0;
        for (integer op = 0; op < 8; op = op + 1)
            for (integer i = 0; i < 6; i = i + 1)
                for (integer j = 0; j < 6; j = j + 1)
                    run_case(op[2:0], edges[i], edges[j]);
        for (integer k = 0; k < 40; k = k + 1) begin
            a = $random;
            b = $random;
            for (integer op = 0; op < 8; op = op + 1)
                run_case(op[2:0], a, b);
        end

        // A younger divide disappears at squash and never reports a result.
        @(negedge clock);
        exec_valid = 1;
        exec_payload = {5'd4, 3'd5, 6'd33, 32'hcafebabe, 32'd7};
        @(posedge clock);
        #1 exec_valid = 0;
        repeat (4) @(posedge clock);
        @(negedge clock);
        squash_valid = 1;
        squash_tag = 5'd2;
        @(posedge clock);
        #1;
        if (result_valid || !exec_ready) $fatal(1, "younger divide survived squash");
        @(negedge clock) squash_valid = 0;
        repeat (34) begin
            @(posedge clock);
            #1;
            if (result_valid) $fatal(1, "squashed divide reappeared");
        end

        // A result waiting for writeback is also cancelled when younger.
        @(negedge clock);
        exec_valid = 1;
        exec_payload = {5'd4, 3'd5, 6'd33, 32'd123, 32'd0};
        @(posedge clock);
        #1 exec_valid = 0;
        expect_result(5'd4, 6'd33, 32'hffffffff);
        @(negedge clock) squash_valid = 1;
        @(posedge clock);
        #1;
        if (result_valid || !exec_ready) $fatal(1, "held result survived squash");
        @(negedge clock) squash_valid = 0;

        // An older multiply result is retained across the same boundary.
        @(negedge clock);
        exec_valid = 1;
        exec_payload = {5'd1, 3'd1, 6'd34, 32'h80000000, 32'd2};
        @(posedge clock);
        #1 exec_valid = 0;
        expect_result(5'd1, 6'd34, 32'hffffffff);
        @(negedge clock) squash_valid = 1;
        @(posedge clock);
        #1;
        expect_result(5'd1, 6'd34, 32'hffffffff);
        @(negedge clock) squash_valid = 0;

        // Consume one result and launch the next request on the same edge.
        @(negedge clock);
        result_ready = 1;
        exec_valid = 1;
        exec_payload = {5'd2, 3'd0, 6'd36, 32'd6, 32'd7};
        #1;
        if (!exec_ready) $fatal(1, "no back-to-back acceptance");
        @(posedge clock);
        #1;
        result_ready = 0;
        exec_valid = 0;
        expect_result(5'd2, 6'd36, 32'd42);
        @(negedge clock) result_ready = 1;
        @(posedge clock);
        #1 result_ready = 0;

        // Reset discards a long-running operation.
        @(negedge clock);
        exec_valid = 1;
        exec_payload = {5'd3, 3'd4, 6'd37, 32'd100, 32'd3};
        @(posedge clock);
        #1 exec_valid = 0;
        @(negedge clock) reset = 1;
        @(posedge clock);
        #1;
        if (result_valid || !exec_ready) $fatal(1, "reset did not cancel divide");
        @(negedge clock) reset = 0;
        repeat (33) begin
            @(posedge clock);
            #1;
            if (result_valid) $fatal(1, "reset divide reappeared");
        end
        run_case(3'd6, 32'hfffffffa, 32'd4);
        $display("PASS mul_div: %0d arithmetic and latency cases, control cases", checked);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "mul_div test timeout");
    end
endmodule
