`timescale 1ns/1ps
module mul_div_tb;
    localparam integer RW=3, PW=6, EB=RW+3+PW+64, RB=RW+PW+32;
    reg clock=0;
    always #5 clock=~clock;
    reg reset=1, squash_valid=0, exec_valid=0, result_ready=0;
    reg [RW-1:0] squash_tag=0, rob_head=0;
    reg [EB-1:0] exec_payload=0;
    wire exec_ready, result_valid;
    wire [RB-1:0] result_payload;
    reg [31:0] edges [0:9];
    reg [31:0] random_a, random_b;
    reg [RB-1:0] saved_result;
    integer op, a_index, b_index, iteration, phase, seed=32'h56a11ace;
    integer cases_run=0;
    reg [RW-1:0] next_tag=0;
    mul_div #(.ROB_DEPTH(8), .PRF_SIZE(40)) dut (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .exec_valid, .exec_ready, .exec_payload,
        .result_valid, .result_ready, .result_payload);

    task tick;
        begin @(posedge clock); #1; end
    endtask

    function automatic [31:0] reference_value;
        input [2:0] operation;
        input [31:0] a, b;
        reg signed [63:0] extended_a, extended_b;
        reg signed [127:0] product;
        reg signed [63:0] divided;
        begin
            extended_a={32'b0,a};
            extended_b={32'b0,b};
            if (operation==1 || operation==2 || operation==4 || operation==6)
                extended_a={{32{a[31]}},a};
            if (operation==1 || operation==4 || operation==6)
                extended_b={{32{b[31]}},b};
            product=extended_a*extended_b;
            if (operation<4)
                reference_value=(operation==0)?product[31:0]:product[63:32];
            else if (b==0)
                reference_value=operation[1]?a:32'hffffffff;
            else begin
                if (operation[1]) divided=extended_a%extended_b;
                else divided=extended_a/extended_b;
                reference_value=divided[31:0];
            end
        end
    endfunction

    task check_result;
        input [RW-1:0] tag;
        input [PW-1:0] pdst;
        input [31:0] value;
        begin
            if (!result_valid || result_payload!=={tag,pdst,value})
                $fatal(1,"result mismatch: got valid=%b payload=%h expected=%h",
                       result_valid,result_payload,{tag,pdst,value});
        end
    endtask

    task run_case;
        input [2:0] operation;
        input [31:0] a, b;
        input integer stalls;
        reg [31:0] expected;
        reg [RW-1:0] tag;
        reg [PW-1:0] pdst;
        integer latency, step;
        begin
            expected=reference_value(operation,a,b);
            tag=next_tag;
            pdst=PW'(cases_run%40);
            next_tag=next_tag+1'b1;
            latency=(operation<4)?3:32;
            if (operation>=4 && (b==0 ||
                ((operation==4 || operation==6) && a==32'h80000000 && b==32'hffffffff)))
                latency=0;
            @(negedge clock);
            result_ready=0;
            exec_valid=1;
            exec_payload={tag,operation,pdst,a,b};
            #1;
            if (!exec_ready) $fatal(1,"unit did not accept idle request");
            tick;
            exec_valid=0;
            exec_payload=0;
            if (latency!=0 && (result_valid || exec_ready))
                $fatal(1,"request completed or unit ready too early");
            for (step=1; step<=latency; step=step+1) begin
                tick;
                if (step<latency && (result_valid || exec_ready))
                    $fatal(1,"operation %d completed early at cycle %d",operation,step);
            end
            check_result(tag,pdst,expected);
            for (step=0; step<stalls; step=step+1) begin
                tick;
                check_result(tag,pdst,expected);
                if (exec_ready) $fatal(1,"backpressure did not block acceptance");
            end
            @(negedge clock); result_ready=1; #1;
            if (!exec_ready) $fatal(1,"result consumption must allow a new request");
            tick;
            if (result_valid || !exec_ready) $fatal(1,"result handshake failed");
            cases_run=cases_run+1;
        end
    endtask

    // Kill a wrapped younger tag in every multiply stage and in RESULT.
    task cancel_multiply;
        input integer cycles_before_squash;
        integer step;
        begin
            @(negedge clock);
            rob_head=6;
            result_ready=0;
            exec_valid=1;
            exec_payload={3'd1,3'd1,6'd35,32'h80000001,32'hffffffff};
            tick; exec_valid=0;
            for (step=0; step<cycles_before_squash; step=step+1) tick;
            @(negedge clock); squash_valid=1; squash_tag=7;
            tick;
            @(negedge clock); squash_valid=0;
            for (step=0; step<4; step=step+1) begin
                tick;
                if (result_valid || !exec_ready) $fatal(1,"squashed multiply survived");
            end
            rob_head=0;
        end
    endtask

    initial begin
        edges[0]=0; edges[1]=1; edges[2]=2; edges[3]=32'h7fffffff;
        edges[4]=32'h80000000; edges[5]=32'h80000001; edges[6]=32'hffffffff;
        edges[7]=32'hfffffffe; edges[8]=32'h55555555; edges[9]=32'haaaaaaaa;
        tick;
        @(negedge clock); reset=0;
        for (op=0; op<8; op=op+1)
            for (a_index=0; a_index<10; a_index=a_index+1)
                for (b_index=0; b_index<10; b_index=b_index+1)
                    run_case(3'(op),edges[a_index],edges[b_index],(a_index+b_index)%3);
        for (iteration=0; iteration<1000; iteration=iteration+1) begin
            random_a=$random(seed);
            random_b=$random(seed);
            for (op=0; op<8; op=op+1)
                run_case(3'(op),random_a,random_b,iteration%3);
        end

        for (phase=0; phase<4; phase=phase+1) begin
            cancel_multiply(phase);
            run_case(3'd2,32'hfffffffe,32'hffffffff,0);
        end

        // Older and equal tags must survive a squash, including ROB wraparound.
        for (phase=0; phase<4; phase=phase+1) begin
            @(negedge clock);
            rob_head=6; result_ready=0; exec_valid=1;
            exec_payload={3'd7,3'd1,6'd32,32'h80000000,32'hffffffff};
            tick; exec_valid=0;
            for (iteration=0; iteration<3; iteration=iteration+1) begin
                @(negedge clock);
                squash_valid=(phase==iteration);
                squash_tag=(phase==1)?3'd7:3'd0;
                tick;
            end
            @(negedge clock); squash_valid=(phase==3); squash_tag=7;
            tick; check_result(3'd7,6'd32,0);
            @(negedge clock); squash_valid=0; result_ready=1;
            tick;
            rob_head=0;
        end

        // Reject a younger incoming request while allowing the boundary tag.
        @(negedge clock);
        rob_head=6; squash_valid=1; squash_tag=7;
        exec_valid=1; exec_payload={3'd0,3'd0,6'd33,32'd9,32'd9};
        tick;
        if (result_valid || !exec_ready) $fatal(1,"accepted squashed incoming request");
        @(negedge clock); exec_payload={3'd7,3'd0,6'd33,32'd9,32'd9};
        tick;
        exec_valid=0;
        @(negedge clock); squash_valid=0; result_ready=0;
        repeat (3) tick;
        check_result(3'd7,6'd33,81);

        // Consume a multiply while accepting DIV, then consume DIV with MUL.
        @(negedge clock);
        exec_valid=1; result_ready=1;
        exec_payload={3'd0,3'd4,6'd34,32'hfffffff9,32'd3};
        #1;
        if (!exec_ready) $fatal(1,"no simultaneous result/request handshake");
        tick; exec_valid=0; result_ready=0;
        for (iteration=1; iteration<=32; iteration=iteration+1) begin
            tick;
            if (iteration<32 && result_valid) $fatal(1,"division latency changed");
        end
        check_result(3'd0,6'd34,32'hfffffffe);
        @(negedge clock);
        exec_valid=1; result_ready=1;
        exec_payload={3'd1,3'd3,6'd35,32'hffffffff,32'hffffffff};
        tick; exec_valid=0; result_ready=0;
        repeat (3) tick;
        check_result(3'd1,6'd35,32'hfffffffe);
        saved_result=result_payload;
        @(negedge clock);
        exec_valid=1; exec_payload={3'd2,3'd0,6'd36,32'd11,32'd13};
        repeat (4) begin
            tick;
            if (exec_ready || result_payload!==saved_result)
                $fatal(1,"pending request overwrote blocked result");
        end
        @(negedge clock); result_ready=1;
        tick; exec_valid=0; result_ready=0;
        repeat (3) tick;
        check_result(3'd2,6'd36,143);
        @(negedge clock); result_ready=1;
        tick;

        // Reset cancels all three multiply stages and a held result.
        for (phase=0; phase<4; phase=phase+1) begin
            @(negedge clock);
            exec_valid=1; result_ready=0;
            exec_payload={3'd0,3'd3,6'd37,32'hffffffff,32'h80000000};
            tick; exec_valid=0;
            repeat (phase) tick;
            @(negedge clock); reset=1;
            tick;
            if (result_valid || !exec_ready) $fatal(1,"reset did not clear multiply");
            @(negedge clock); reset=0;
            repeat (4) begin
                tick;
                if (result_valid) $fatal(1,"stale result after reset");
            end
            run_case(3'd0,32'd19,32'd23,0);
        end
        $display("PASS mul_div: %0d arithmetic cases, three-cycle Wallace latency, DIV latency, backpressure, handoff, squash, reset",cases_run);
        $finish;
    end
    initial begin #5000000; $fatal(1,"timeout"); end
endmodule
