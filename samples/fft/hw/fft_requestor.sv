// fft_requestor.sv

import ccip_if_pkg::*;
import fft_pkg::*;

module fft_requestor
#(
  parameter FFT_FIFO_DEPTH = 8
)
(
  input  logic           clk,
  input  logic           reset,
  input  logic [31:0]    hc_control,
  input  t_ccip_clAddr   hc_dsm_base,
  input  t_hc_buffer     hc_buffer[HC_BUFFER_SIZE],
  input  logic [511:0]   data_in,
  input  logic           next_in,
  input  t_if_ccip_Rx    ccip_rx,
  output t_if_ccip_c0_Tx ccip_c0_tx,
  output t_if_ccip_c1_Tx ccip_c1_tx,
  output logic [511:0]   data_out,
  output logic           next_out
);

  t_block enq_data;
  t_block deq_data;

  logic enq_en;
  logic not_full;
  logic deq_en;
  logic not_empty;

  logic [3:0] counter;
  logic [3:0] dec_counter;

  fft_fifo
  #(
    FFT_FIFO_DEPTH
  )
  uu_fft_fifo
  (
    .clk         (clk),
    .reset       (reset),
    .enq_data    (enq_data),
    .enq_en      (enq_en),
    .not_full    (not_full),
    .deq_data    (deq_data),
    .deq_en      (deq_en),
    .not_empty   (not_empty),
    .counter     (counter),
    .dec_counter (dec_counter)
  );

  //
  // send data to fft
  //

  t_ccip_clAddr rd_offset;
  t_ccip_clAddr rd_rsp_cnt;

  logic [1:0] send_cnt;

  always_ff@(posedge clk or posedge reset) begin
    if (reset) begin
      send_cnt <= 2'h0;
      next_out <= 1'b0;

      data_out <= '0;
      deq_en   <= 1'b0;
    end
    else begin
      if ((send_cnt == '0) && (counter > 1)) begin
        send_cnt <= 2'h2;
        next_out <= 1'b1;
      end
      else begin
        next_out <= 1'b0;
      end

      if (send_cnt != 0) begin
        data_out <= deq_data;
        deq_en   <= 1'b1;
        send_cnt <= send_cnt - 2'h1;
      end
      else begin
        deq_en   <= 1'b0;
      end
    end
  end

  //
  // read state FSM
  //

  logic [31:0] cnt_request;

  t_rd_state rd_state;
  t_rd_state rd_next_state;

  t_ccip_c0_ReqMemHdr rd_hdr;

  always_ff@(posedge clk or posedge reset) begin
    if (reset) begin
      cnt_request <= '0;
    end
    else begin
      logic [31:0] request;
      logic [31:0] response;

      if ((rd_state == S_RD_FETCH) &&
        (cnt_request < FFT_FIFO_DEPTH) &&
        !ccip_rx.c0TxAlmFull) begin

        request = 32'h1;
      end
      else begin
        request = 32'h0;
      end

      if ((ccip_rx.c0.rspValid) &&
        (ccip_rx.c0.hdr.resp_type == eRSP_RDLINE)) begin
        response = 32'h1;
      end
      else begin
        response = 32'h0;
      end

      cnt_request <= cnt_request + request - response;
    end
  end

  always_ff@(posedge clk or posedge reset) begin
    if (reset) begin
      ccip_c0_tx.valid    <= 1'b0;
      rd_offset           <= '0;

      rd_hdr = t_ccip_c0_ReqMemHdr'(0);
    end
    else begin
      case (rd_state)
      S_RD_IDLE:
        begin
          ccip_c0_tx.valid <= 1'b0;
        end

      S_RD_FETCH:
        begin
          if (cnt_request >= FFT_FIFO_DEPTH) begin
            ccip_c0_tx.valid <= 1'b0;
          end
          else if (!ccip_rx.c0TxAlmFull) begin
            rd_hdr.cl_len  = eCL_LEN_1;
            rd_hdr.address = hc_buffer[1].address + rd_offset;

            ccip_c0_tx.valid    <= 1'b1;
            ccip_c0_tx.hdr      <= rd_hdr;
            rd_offset           <= t_ccip_clAddr'(rd_offset + 1);
          end
          else begin
            ccip_c0_tx.valid <= 1'b0;
          end
        end

      S_RD_WAIT:
        begin
          ccip_c0_tx.valid <= 1'b0;
        end

      S_RD_FINISH:
        begin
          ccip_c0_tx.valid <= 1'b0;
        end
      endcase
    end
  end

  always_ff@(posedge clk or posedge reset) begin
    if (reset) begin
      rd_state <= S_RD_IDLE;
    end
    else begin
      rd_state <= rd_next_state;
    end
  end

  always_comb begin
    rd_next_state = rd_state;

    case (rd_state)
    S_RD_IDLE:
      begin
        if (hc_control == HC_CONTROL_START) begin
          rd_next_state = S_RD_FETCH;
        end
      end

    S_RD_FETCH:
      begin
        if (cnt_request >= FFT_FIFO_DEPTH) begin
          rd_next_state = S_RD_WAIT;
        end
        else if (!ccip_rx.c0TxAlmFull && ((rd_offset + 1) == hc_buffer[1].size)) begin
          rd_next_state = S_RD_FINISH;
        end
      end

    S_RD_WAIT:
      begin
        if (cnt_request < FFT_FIFO_DEPTH) begin
          rd_next_state = S_RD_FETCH;
        end
      end

    endcase
  end

  // Receive data (read responses).
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      rd_rsp_cnt <= '0;
      enq_en     <= '0;
      enq_data   <= '0;
    end
    else begin
      if ((ccip_rx.c0.rspValid) &&
        (ccip_rx.c0.hdr.resp_type == eRSP_RDLINE)) begin

        rd_rsp_cnt <= t_ccip_clAddr'(rd_rsp_cnt + 1);

        enq_en   <= 1'b1;
        enq_data <= ccip_rx.c0.data;
      end
      else begin
        enq_en <= 1'b0;
      end
    end
  end

  //
  // write state FSM
  //

  t_wr_state wr_state;
  t_wr_state wr_next_state;

  t_ccip_clAddr wr_offset;
  t_ccip_clAddr wr_rsp_cnt;

  t_ccip_c1_ReqMemHdr wr_hdr;

  // Receive data (write responses).
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      wr_rsp_cnt <= '0;
    end
    else begin
      if ((ccip_rx.c1.rspValid) &&
        (ccip_rx.c1.hdr.resp_type == eRSP_WRLINE)) begin

        wr_rsp_cnt <= t_ccip_clAddr'(wr_rsp_cnt + 1);
      end
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      wr_offset  <= '0;

      wr_hdr = t_ccip_c1_ReqMemHdr'(0);
      ccip_c1_tx.hdr   <= wr_hdr;
      ccip_c1_tx.valid <= 1'b0;
      ccip_c1_tx.data  <= t_ccip_clData'('0);
    end
    else begin
      case (wr_state)
      S_WR_IDLE:
        begin
          ccip_c1_tx.valid <= 1'b0;
        end

      S_WR_WAIT:
        begin
          ccip_c1_tx.valid <= 1'b0;
        end

      S_WR_DATA:
        begin
          if (!ccip_rx.c1TxAlmFull) begin
            wr_hdr.address = hc_buffer[0].address + wr_offset;
            wr_hdr.sop = 1'b1;

            ccip_c1_tx.hdr   <= wr_hdr;
            ccip_c1_tx.valid <= 1'b1;
            ccip_c1_tx.data  <= t_ccip_clData'(data_in);
            wr_offset        <= t_ccip_clAddr'(wr_offset + 1);
          end
          else begin
            ccip_c1_tx.valid <= 1'b0;
          end
        end

      S_WR_FINISH_1:
        begin
          if (!ccip_rx.c1TxAlmFull && (wr_rsp_cnt == hc_buffer[0].size)) begin
            wr_hdr.address = hc_dsm_base + 1;
            wr_hdr.sop = 1'b1;

            ccip_c1_tx.hdr   <= wr_hdr;
            ccip_c1_tx.valid <= 1'b1;
            ccip_c1_tx.data  <= t_ccip_clData'('h1);
          end
          else begin
            ccip_c1_tx.valid <= 1'b0;
          end
        end

      S_WR_FINISH_2:
        begin
          ccip_c1_tx.valid <= 1'b0;
        end

      endcase
    end
  end

  always_ff@(posedge clk or posedge reset) begin
    if (reset) begin
      wr_state <= S_WR_IDLE;
    end
    else begin
      wr_state <= wr_next_state;
    end
  end

  always_comb begin
    wr_next_state = wr_state;

    case (wr_state)
      S_WR_IDLE:
        begin
          if (hc_control == HC_CONTROL_START) begin
            wr_next_state = S_WR_WAIT;
          end
        end

      S_WR_WAIT:
        begin
          if (next_in) begin
            wr_next_state <= S_WR_DATA;
          end
          else if (wr_offset == hc_buffer[0].size) begin
            wr_next_state <= S_WR_FINISH_1;
          end
        end

      S_WR_DATA:
        begin
          if (!ccip_rx.c1TxAlmFull && wr_offset[0]) begin
            wr_next_state = S_WR_WAIT;
          end
        end

      S_WR_FINISH_1:
        begin
          if (!ccip_rx.c1TxAlmFull && (wr_rsp_cnt == hc_buffer[0].size)) begin
            wr_next_state = S_WR_FINISH_2;
          end
        end
    endcase
  end

endmodule : fft_requestor
