(* cp(1) built with liburing. Queues up as many reads as the queue
 * depth allows and then queues up corresponding writes.
   OCaml version of https://unixism.net/loti/tutorial/cp_liburing.html *)

let get_file_size fd =
  Unix.handle_unix_error Unix.fstat fd |>
  fun {Unix.st_size; _} -> st_size
(* TODO make this work with ST_ISBLK *)

type t = {
  mutable insize: int;
  mutable offset: int;
  mutable reads: int;
  mutable writes: int;
  mutable write_left: int;
  mutable read_left: int;
  block_size: int;
  infd: Unix.file_descr;
  outfd: Unix.file_descr;
}

let pp ppf {insize;offset;reads;writes;write_left; read_left;_} =
  Fmt.pf ppf "insize %d offset %d reads %d writes %d rleft %d wleft %d"
    insize offset reads writes read_left write_left

type req = {
  op: [`R | `W ];
  iov: Iovec.t;
  len: int;
  fileoff: int;
  mutable off: int;
  t : t;
}

let pp_req ppf {op; len; off; fileoff; t; _ } =
  Fmt.pf ppf "[%s fileoff %d len %d off %d] [%a]" (match op with |`R -> "r" |`W -> "w") fileoff len off pp t

let empty_req t = { op=`R; iov=Iovec.empty; len=0; off=0; fileoff=0; t}

(* Perform a complete read into bufs. *)
let queue_read uring t len =
  let ba = Iovec.Buffer.create len in
  let iov = Iovec.alloc [|ba|] in
  let req = { op=`R; iov; fileoff=t.offset; len; off=0; t } in
  Logs.debug (fun l -> l "queue_read: %a" pp_req req);
  let r = Uring.readv uring ~offset:t.offset t.infd iov req in
  assert(r);
  t.offset <- t.offset + len;
  t.read_left <- t.read_left - len;
  t.reads <- t.reads + 1

(* TODO compile time check *)
let eagain = -11
let eintr = -4

(* Check that a read has completely finished, and if not
 * queue it up for completing the remaining amount *)
let handle_read_completion uring req res =
  Logs.debug (fun l -> l "read_completion: res=%d %a" res pp_req req);
  let bytes_to_read = req.len - req.off in
  match res with
  | 0 ->
    Logs.debug (fun l -> l "eof %a" pp_req req);
  | n when n = eagain || n = eintr ->
    (* requeue the request *)
    let r = Uring.readv ~offset:req.fileoff uring req.t.infd req.iov req in
    assert(r);
    Logs.debug (fun l -> l "requeued eintr read: %a" pp_req req);
  | n when n < 0 ->
    raise (Failure ("unix errorno " ^ (string_of_int n)))
  | n when n < bytes_to_read ->
    (* handle short read so new iovec and resubmit *)
    Iovec.advance req.iov ~idx:0 ~adj:n;
    req.off <-req.off + n;
    let r = Uring.readv ~offset:req.off uring req.t.infd req.iov req in
    assert(r);
    Logs.debug (fun l -> l "requeued short read: %a" pp_req req);
  | n when n = bytes_to_read ->
    (* Read is complete, all bytes are read, turn it into a write *)
    req.t.reads <- req.t.reads - 1;
    req.t.writes <- req.t.writes + 1;
    (* reset the iovec *)
    Iovec.advance req.iov ~idx:0 ~adj:(req.off * -1);
    let req = { req with op=`W; off=0 } in
    let r = Uring.writev uring ~offset:req.fileoff req.t.outfd req.iov req in
    assert(r);
    Logs.debug (fun l -> l "queued write: %a" pp_req req);
  | n -> raise (Failure (Printf.sprintf "unexpected readv result %d > %d " bytes_to_read n))

let handle_write_completion uring req res =
  Logs.debug (fun l -> l "write_completion: res=%d %a" res pp_req req);
  let bytes_to_write = req.len - req.off in
  match res with
  | 0 -> raise End_of_file
  | n when n = eagain || n = eintr ->
    (* requeue the request *)
    let r = Uring.writev ~offset:req.fileoff uring req.t.infd req.iov req in
    assert(r);
    Logs.debug (fun l -> l "requeued eintr read: %a" pp_req req);
  | n when n < bytes_to_write ->
    (* handle short write so new iovec and resubmit *)
    Iovec.advance req.iov ~idx:0 ~adj:n;
    req.off <- req.off + n;
    let r = Uring.writev ~offset:req.fileoff uring req.t.infd req.iov req in
    assert(r);
    Logs.debug (fun l -> l "requeued write read: %a" pp_req req);
  | n when n = bytes_to_write ->
    req.t.writes <- req.t.writes - 1;
    req.t.write_left <- req.t.write_left - req.len;
    Logs.debug (fun l -> l "write done: %a" pp_req req);
    Iovec.free req.iov
  | n -> raise (Failure (Printf.sprintf "unexpected writev result %d > %d " bytes_to_write n))

let handle_completion uring req res =
  match req.op with
  |`R -> handle_read_completion uring req res
  |`W -> handle_write_completion uring req res

let copy_file uring t =
  (* Create a set of read requests that we will turn into write requests
   * up until the queue depth *)
  while t.write_left > 0 || t.read_left > 0 do
    let rec submit_reads () =
      if t.read_left > 0 then begin
        if t.reads + t.writes < (Uring.queue_depth uring) then begin
          let size = min t.block_size t.read_left in
          queue_read uring t size;
          submit_reads ()
        end
      end;
    in
    submit_reads ();
    let num = Uring.submit uring in
    Logs.debug (fun l -> l "%a: %d" Fmt.(styled `Yellow string) "submit" num);
    (* Queue now full, find at least one completion *)
    let got_completion = ref false in
    let rec handle_completions () =
      if t.write_left > 0 then begin
        let check_q = if !got_completion then Uring.peek uring else Uring.wait uring  in
        match check_q with
        |None -> Logs.debug (fun l -> l "completions: retry so finishing loop")
        |Some (req, res) ->  
          handle_completion uring req res;
          got_completion := true;
          handle_completions ();
      end
    in
    handle_completions ();
    let num = Uring.submit uring in
    Logs.debug (fun l -> l "%a: %d" Fmt.(styled `Yellow string) "submit" num);
  done

let run_cp block_size queue_depth infile outfile () =
   let infd = Unix.(handle_unix_error (openfile infile [O_RDONLY]) 0) in
   let outfd = Unix.(handle_unix_error (openfile outfile [O_WRONLY; O_CREAT; O_TRUNC]) 0o644) in
   let insize = get_file_size infd in
   let t = { block_size; insize; offset=0; reads=0; writes=0; write_left=insize; read_left=insize; infd; outfd } in
   Logs.debug (fun l -> l "starting: %a bs=%d qd=%d" pp t block_size queue_depth);
   let uring = Uring.create ~queue_depth ~default:(empty_req t) () in
   copy_file uring t;
   Unix.close infd;
   Unix.close outfd;
   Uring.exit uring;
   Gc.compact () (* TODO to aid debugging with valgrind, remove soon *)
