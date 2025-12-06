`timescale 1ns/1ps

`define START_TESTBENCH error_o = 0; pass_o = 0; #10;
`define FINISH_WITH_FAIL error_o = 1; pass_o = 0; #10; $finish();
`define FINISH_WITH_PASS pass_o = 1; error_o = 0; #10; $finish();

module testbench
  (output logic error_o = 1'bx,
   output logic pass_o  = 1'bx);

  localparam width_p = 8;

  logic clk_i;
  logic reset_i;

  logic [width_p-1:0] red_i, green_i, blue_i;
  logic        valid_i;
  logic        ready_o;
  logic [width_p-1:0] gray_o;
  logic        valid_o;
  logic        ready_i;

  nonsynth_clock_gen
    #(.cycle_time_p(10))
  cg (.clk_o(clk_i));

  nonsynth_reset_gen
    #(.reset_cycles_lo_p(1),
      .reset_cycles_hi_p(10))
  rg (.clk_i(clk_i),
      .async_reset_o(reset_i));

  rgb2gray #() dut (
    .clk_i(clk_i),
    .reset_i(reset_i),
    .red_i(red_i),
    .green_i(green_i),
    .blue_i(blue_i),
    .valid_i(valid_i),
    .ready_o(ready_o),
    .valid_o(valid_o),
    .gray_o(gray_o),
    .ready_i(ready_i)
  );

  localparam [15:0] red = 16'd19595;
  localparam [15:0] green = 16'd38470;
  localparam [15:0] blue = 16'd7471;

  logic [width_p-1:0] r_queue[$], g_queue[$], b_queue[$];
  logic [width_p-1:0] exp_queue[$];

  integer num_sent, num_recv;
  integer max_abs_err;
  longint sum_sq_err;
  integer diff, abs_diff;
  
  localparam integer RMSE_THRESH = 1;
  localparam integer MAX_SINGLE_ERR = 3;
  
  integer protocol_errors;
  logic prev_valid_o, prev_ready_i;
  logic [width_p-1:0] prev_gray_o;
  
  logic prev_valid_i, prev_ready_o;
  logic [width_p-1:0] prev_red_i, prev_green_i, prev_blue_i;

  logic wr, rd;
  logic [26:0] ref_sum;
  logic [width_p-1:0] exp_gray;
  logic [width_p-1:0] cur_r, cur_g, cur_b, cur_exp;

  always @(posedge clk_i) begin
    #1; 
    if ($isunknown(valid_o)) begin
      $display("[%0t] PROTOCOL ERROR: valid_o is X or Z!", $time);
      protocol_errors++;
    end
    if ($isunknown(ready_o)) begin
      $display("[%0t] PROTOCOL ERROR: ready_o is X or Z!", $time);
      protocol_errors++;
    end
    if (valid_o === 1'b1 && $isunknown(gray_o)) begin
      $display("[%0t] PROTOCOL ERROR: gray_o contains X while valid_o asserted!", $time);
      protocol_errors++;
    end
  end

  always @(posedge clk_i) begin
    if (reset_i) begin
      #1; 
      if ($isunknown(valid_o)) begin
        $display("[%0t] PROTOCOL ERROR: valid_o is X or Z during reset!", $time);
        protocol_errors++;
      end
      if ($isunknown(ready_o)) begin
        $display("[%0t] PROTOCOL ERROR: ready_o is X or Z during reset!", $time);
        protocol_errors++;
      end
    end
  end

  always @(posedge clk_i) begin
    if (!reset_i) begin
      if (prev_valid_o && !prev_ready_i && !valid_o) begin
        $display("[%0t] PROTOCOL ERROR: valid_o dropped without ready_i!", $time);
        protocol_errors++;
      end
      if (prev_valid_o && !prev_ready_i && valid_o && (gray_o !== prev_gray_o)) begin
        $display("[%0t] PROTOCOL ERROR: gray_o changed during stall! (%3d -> %3d)", 
          $time, prev_gray_o, gray_o);
        protocol_errors++;
      end
      prev_valid_o <= valid_o;
      prev_ready_i <= ready_i;
      prev_gray_o <= gray_o;
    end else begin
      prev_valid_o <= 0;
      prev_ready_i <= 1;
    end
  end
  
  always @(posedge clk_i) begin
    if (reset_i && valid_o === 1'b1) begin
      $display("[%0t] PROTOCOL ERROR: valid_o high during reset!", $time);
      protocol_errors++;
    end
  end

  always @(posedge clk_i) begin
    if (!reset_i) begin
      wr = (valid_i === 1'b1) && (ready_o === 1'b1);
      rd = (valid_o === 1'b1) && (ready_i === 1'b1);
      if (wr) begin
        ref_sum = (red_i * red) + (green_i * green) + (blue_i * blue);
        exp_gray = ref_sum >> 16;
        r_queue.push_back(red_i);
        g_queue.push_back(green_i);
        b_queue.push_back(blue_i);
        exp_queue.push_back(exp_gray);
        num_sent++;
        $display("[%0t] SEND[%0d]: RGB(%3d,%3d,%3d) -> Expected=%3d", 
                 $time, num_sent, red_i, green_i, blue_i, exp_gray);
      end
      if (rd) begin
        num_recv++;
        if (exp_queue.size() > 0) begin
          cur_r = r_queue.pop_front();
          cur_g = g_queue.pop_front();
          cur_b = b_queue.pop_front();
          cur_exp = exp_queue.pop_front();
          diff = gray_o - cur_exp;
          abs_diff = (diff < 0) ? -diff : diff;
          sum_sq_err = sum_sq_err + (diff * diff);
          if (abs_diff > max_abs_err) max_abs_err = abs_diff;
          if (diff != 0) begin
            $display("[%0t] RECV[%0d]: RGB(%3d,%3d,%3d) -> Gray=%3d, Expected=%3d, Err=%0d",
                     $time, num_recv, cur_r, cur_g, cur_b, gray_o, cur_exp, diff);
          end else begin
            $display("[%0t] RECV[%0d]: RGB(%3d,%3d,%3d) -> Gray=%3d OK",
              $time, num_recv, cur_r, cur_g, cur_b, gray_o);
          end
        end else begin
          $display("[%0t] PROTOCOL ERROR: Extra output received (no input queued)!", $time);
          protocol_errors++;
        end
      end
    end
  end

  integer i;

  initial begin
    `START_TESTBENCH
    repeat (5) @(posedge clk_i);
    #1;
    valid_i = 0;
    ready_i = 1;
    red_i   = 0;
    green_i = 0;
    blue_i  = 0;
    num_sent = 0;
    num_recv = 0;
    sum_sq_err = 0;
    max_abs_err = 0;
    protocol_errors = 0;

    $display("[%0t] === Testing Corner Cases ===", $time);
    @(posedge clk_i); 
    #1;
    valid_i = 1; red_i = 0; green_i = 0; blue_i = 0;
    @(posedge clk_i); 
    #1;
    valid_i = 0;

    repeat(3) @(posedge clk_i);

    @(posedge clk_i); 
    #1;
    valid_i = 1; 
    red_i = 255; 
    green_i = 255; 
    blue_i = 255;
    @(posedge clk_i); 
    #1;
    valid_i = 0;

    repeat(3) @(posedge clk_i);

    @(posedge clk_i); 
    #1;
    valid_i = 1; 
    red_i = 255; 
    green_i = 0; 
    blue_i = 0;
    @(posedge clk_i); 
    #1;
    valid_i = 0;

    repeat(3) @(posedge clk_i);

    @(posedge clk_i); 
    #1;
    valid_i = 1; 
    red_i = 0; 
    green_i = 255; 
    blue_i = 0;
    @(posedge clk_i); 
    #1;
    valid_i = 0;

    repeat(3) @(posedge clk_i);

    @(posedge clk_i); 
    #1;
    valid_i = 1; 
    red_i = 0; 
    green_i = 0; 
    blue_i = 255;
    @(posedge clk_i); 
    #1;
    valid_i = 0;

    repeat(3) @(posedge clk_i);

    @(posedge clk_i); 
    #1;
    valid_i = 1; 
    red_i = 128; 
    green_i = 128; 
    blue_i = 128;
    @(posedge clk_i); 
    #1;
    valid_i = 0;

    repeat(5) @(posedge clk_i);

    $display("[%0t] === Testing Output Backpressure ===", $time);
    @(posedge clk_i); 
    #1;
    valid_i = 1; 
    red_i = 100; 
    green_i = 150; 
    blue_i = 200;
    @(posedge clk_i); 
    #1;
    valid_i = 0;
    ready_i = 0; 
    
    repeat(10) @(posedge clk_i);
    
    ready_i = 1;  

    repeat(5) @(posedge clk_i);

    $display("[%0t] === Testing Input While Output Stalled ===", $time);
    @(posedge clk_i); 
    #1;
    valid_i = 1; 
    red_i = 50; 
    green_i = 100; 
    blue_i = 150;
    @(posedge clk_i); 
    #1;
    valid_i = 0;
    
    repeat(3) @(posedge clk_i);

    ready_i = 0;
    
    @(posedge clk_i); 
    #1;
    valid_i = 1; 
    red_i = 200; 
    green_i = 100; 
    blue_i = 50;

    repeat(5) @(posedge clk_i);

    #1; 
    valid_i = 0;
    ready_i = 1;

    repeat(10) @(posedge clk_i);

    $display("[%0t] === Testing Back-to-Back Streaming ===", $time);
    for (i = 0; i < 20; i++) begin
      @(posedge clk_i); 
      #1;
      if (ready_o === 1'b1) begin
        valid_i = 1;
        red_i   = i * 12;
        green_i = i * 10;
        blue_i  = i * 8;
      end else begin
        valid_i = 0;
        i = i - 1; 
      end
    end
    @(posedge clk_i); 
    #1;
    valid_i = 0;

    repeat(10) @(posedge clk_i);

    $display("[%0t] === Testing Random Backpressure ===", $time);
    for (i = 0; i < 50; i++) begin
      @(posedge clk_i); 
      #1;
      ready_i = ($urandom_range(0, 3) != 0);
      if ((ready_o === 1'b1) && ($urandom_range(0, 1) == 1)) begin
        valid_i = 1;
        red_i   = $urandom_range(0, 255);
        green_i = $urandom_range(0, 255);
        blue_i  = $urandom_range(0, 255);
      end else begin
        valid_i = 0;
      end
    end
    @(posedge clk_i); 
    #1;
    valid_i = 0;
    ready_i = 1;
    for (i = 0; i < 30; i = i + 1) begin
      @(posedge clk_i); 
      #1;
      ready_i = ($urandom_range(0, 2) != 0);
    end
    ready_i = 1;

    repeat(20) @(posedge clk_i);

    $display("[%0t] === Draining Pipeline ===", $time);
    repeat(20) @(posedge clk_i);
    #10;
    $display("");
    $display("=== Final Results ===");
    $display("Total sent: %0d", num_sent);
    $display("Total received: %0d", num_recv);
    $display("Protocol errors: %0d", protocol_errors);
    $display("Sum of squared errors: %0d", sum_sq_err);
    $display("Max absolute error: %0d", max_abs_err);
    
    if (num_sent != num_recv) begin
      $display("FAILED: Sent %0d but received %0d values!", num_sent, num_recv);
      `FINISH_WITH_FAIL
    end
    
    if (protocol_errors > 0) begin
      $display("FAILED: %0d protocol violations detected", protocol_errors);
      `FINISH_WITH_FAIL
    end
    
    if (num_recv > 0) begin
      real mse, rmse;
      mse = real'(sum_sq_err) / real'(num_recv);
      rmse = $sqrt(mse);
      $display("Mean squared error: %f", mse);
      $display("RMSE: %f (threshold: %f)", rmse, RMSE_THRESH);
      
      if (max_abs_err > MAX_SINGLE_ERR) begin
        $display("FAILED: Max error %0d exceeds threshold %0d", max_abs_err, MAX_SINGLE_ERR);
        `FINISH_WITH_FAIL
      end else if (rmse <= RMSE_THRESH) begin
        $display("PASSED");
        `FINISH_WITH_PASS
      end else begin
        $display("FAILED: RMSE %f exceeds threshold %f", rmse, RMSE_THRESH);
        `FINISH_WITH_FAIL
      end
    end else begin
      $display("FAILED: No data received!");
      `FINISH_WITH_FAIL
    end
  end

  final begin
    $display("Simulation time is %t", $time);
    if(error_o === 1) begin
      $display("\033[0;31m    ______                    \033[0m");
      $display("\033[0;31m   / ____/_____________  _____\033[0m");
      $display("\033[0;31m  / __/ / ___/ ___/ __ \\/ ___/\033[0m");
      $display("\033[0;31m / /___/ /  / /  / /_/ / /    \033[0m");
      $display("\033[0;31m/_____/_/  /_/   \\____/_/     \033[0m");
      $display("Simulation Failed");
    end else if (pass_o === 1) begin
      $display("\033[0;32m    ____  ___   __________\033[0m");
      $display("\033[0;32m   / __ \\/   | / ___/ ___/\033[0m");
      $display("\033[0;32m  / /_/ / /| | \\__ \\\\__ \\ \033[0m");
      $display("\033[0;32m / ____/ ___ |___/ /__/ / \033[0m");
      $display("\033[0;32m/_/   /_/  |_/____/____/  \033[0m");
      $display();
      $display("Simulation Succeeded!");
    end else begin
      $display("   __  ___   ____ __ _   ______ _       ___   __");
      $display("  / / / / | / / //_// | / / __ \\ |     / / | / /");
      $display(" / / / /  |/ / ,<  /  |/ / / / / | /| / /  |/ / ");
      $display("/ /_/ / /|  / /| |/ /|  / /_/ /| |/ |/ / /|  /  ");
      $display("\\____/_/ |_/_/ |_/_/ |_/\\____/ |__/|__/_/ |_/   ");
      $display("Please set error_o or pass_o!");
    end
  end

endmodule
