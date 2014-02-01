open Printf
open Lwt

open Oraft_util

module Map    = BatMap
module List   = BatList
module Option = BatOption
module Array  = BatArray

module Kernel =
struct
  type status    = Leader | Follower | Candidate
  type term      = Int64.t
  type index     = Int64.t
  type rep_id    = string
  type client_id = string
  type req_id    = client_id * Int64.t

  type config =
      Simple_config of simple_config * passive_peers
    | Joint_config of simple_config * simple_config * passive_peers
  and simple_config = rep_id list
  and passive_peers = rep_id list

  type ('a, 'b) result = [`OK of 'a | `Error of 'b]

  module REPID = struct type t = rep_id let compare = String.compare end
  module IM = Map.Make(Int64)
  module RM = Map.Make(REPID)
  module RS = Set.Make(REPID)

  module CONFIG :
  sig
    type t

    val make         : node_id:rep_id -> config -> t
    val status       : t -> [`Normal | `Transitional | `Joint]
    val target       : t -> (simple_config * passive_peers) option

    (** Returns all peers (including passive). *)
    val peers        : t -> rep_id list

    (** Returns whether the node is included in the configuration (including
      * passive peers). *)
    val mem          : rep_id -> t -> bool

    (** Returns whether the node is an active member of the configuration. *)
    val mem_active   : rep_id -> t -> bool

    val join         : index -> ?passive:passive_peers -> simple_config ->
                         t -> (t * config) option
    val drop         : at_or_after:index -> t -> t

    val has_quorum   : rep_id list -> t -> bool
    val quorum_min   : (rep_id -> Int64.t) -> t -> Int64.t

    val last_commit  : t -> config
    val current      : t -> config

    (* returns the new config and the simple_config we must transition to (if
     * any) when we have just committed a joint config *)
    val commit       : index -> t -> t * (simple_config * passive_peers) option
  end =
  struct
    module S = Set.Make(String)
    type t   = { id : rep_id; conf : conf; active : S.t; }

    and conf =
        Normal of simple_config * passive_peers
      | Transitional of simple_config * index * simple_config * passive_peers
      | Joint of simple_config * simple_config * passive_peers

    let s_of_list = List.fold_left (fun s x -> S.add x s) S.empty

    let make ~node_id:id config =
      let conf, active = match config with
          Simple_config (c, passive) ->
            (Normal (c, passive), s_of_list c)
        | Joint_config (c1, c2, passive) ->
            (Joint (c1, c2, passive), s_of_list (c1 @ c2))
      in
        { id; conf; active; }

    let quorum c = List.length c / 2 + 1

    let target t = match t.conf with
        Normal _ -> None
      | Transitional (_, _, c, passive) | Joint (_, c, passive) -> Some (c, passive)

    let has_quorum votes t =
      let aux_quorum c =
        List.fold_left (fun s x -> if List.mem x c then s + 1 else s) 0 votes >=
        quorum c
      in
        match t.conf with
          | Normal (c, _) -> aux_quorum c
          | Joint (c1, c2, _) | Transitional (c1, _, c2, _) ->
              aux_quorum c1 && aux_quorum c2

    let quorum_min_simple get c =
      let vs = List.(map get c |> sort Int64.compare) in
        try List.nth vs (quorum c - 1) with _ -> 0L

    let quorum_min get t = match t.conf with
        Normal (c, _) -> quorum_min_simple get c
      | Joint (c1, c2, _) | Transitional (c1, _, c2, _) ->
          min (quorum_min_simple get c1) (quorum_min_simple get c2)

    let join idx ?passive:p c2 t = match t.conf with
        | Normal (c1, passive) ->
            let p      = Option.default passive p in
            let active = s_of_list (c1 @ c2) in
            let conf   = Transitional (c1, idx, c2, p) in
            let t      = { t with conf; active; } in
            let target = Joint_config (c1, c2, p) in
              Some (t, target)
        | _ -> None

    let status t = match t.conf with
        Normal _ -> `Normal
      | Transitional _ -> `Transitional
      | Joint _ -> `Joint

    let drop ~at_or_after:n t = match t.conf with
        Normal _ | Joint _ -> t
      | Transitional (c1, m, _, passive) when m >= n ->
          { t with conf = Normal (c1, passive); active = s_of_list c1 }
      | Transitional _ -> t

    let commit idx t = match t.conf with
        Transitional (c1, idx', c2, passive) when idx' <= idx ->
          let conf   = Joint (c1, c2, passive) in
          let active = s_of_list (c1 @ c2) in
            ({ t with conf; active; }, Some (c2, passive))
      | Normal _ | Transitional _ | Joint _  -> (t, None)

    let last_commit t = match t.conf with
        Normal (c, passive) | Transitional (c, _, _, passive) ->
            Simple_config (c, passive)
      | Joint (c1, c2, passive) -> Joint_config (c1, c2, passive)

    let current t = match t.conf with
        Normal (c, passive) -> Simple_config (c, passive)
      | Transitional (c1, _, c2, passive)
      | Joint (c1, c2, passive) -> Joint_config (c1, c2, passive)

    let all t = match t.conf with
        Normal (c, passive) -> [c; passive]
      | Joint (c1, c2, passive) | Transitional (c1, _, c2, passive) ->
          [c1; c2; passive]

    let node_set t =
      all t |> List.concat |>
      List.fold_left (fun s x -> S.add x s) S.empty

    let peers t = node_set t |> S.remove t.id |> S.elements

    let mem id t = node_set t |> S.mem id

    let mem_active id t = S.mem id t.active
  end

  module LOG : sig
    type 'a t

    val empty       : init_index:index -> init_term:term -> 'a t
    val to_list     : 'a t -> (index * 'a * term) list
    val of_list     : init_index:index -> init_term:term ->
                        (index * 'a * term) list -> 'a t
    val append      : term:term -> 'a -> 'a t -> 'a t
    val last_index  : 'a t -> (term * index)

    (** @return new log and index of first conflicting entry (if any) *)
    val append_many : (index * ('a * term)) list -> 'a t -> 'a t * index option
    val get_range   : from_inclusive:index -> to_inclusive:index -> 'a t ->
                      (index * ('a * term)) list
    val get_term    : index -> 'a t -> term option

    val trim_prefix : last_index:index -> last_term:term -> 'a t -> 'a t

    val prev_log_index : 'a t -> index
    val prev_log_term  : 'a t -> term
  end =
  struct
    type 'a t =
        {
          init_index : index;
          init_term  : term;
          last_index : index;
          last_term  : term;
          entries    : ('a * term) IM.t;
        }

    let empty ~init_index ~init_term =
      { init_index; init_term;
        last_index = init_index;
        last_term  = init_term;
        entries    = IM.empty;
      }

    let trim_prefix ~last_index ~last_term t =
      let _, _, entries = IM.split last_index t.entries in
        {
          t with entries;
                 init_index = last_index;
                 init_term  = last_term;
        }

    let prev_log_index t = t.init_index
    let prev_log_term  t = t.init_term

    let to_list t =
      IM.bindings t.entries |> List.map (fun (i, (x, t)) -> (i, x, t))

    let of_list ~init_index ~init_term = function
        [] -> empty ~init_index ~init_term
      | l ->
          let entries =
            List.fold_left
              (fun m (idx, x, term) -> IM.add idx (x, term) m)
              IM.empty l in
          let (init_index, (_, init_term)) = IM.min_binding entries in
          let (last_index, (_, last_term)) = IM.max_binding entries in
            { init_index; init_term; last_index; last_term; entries; }

    let append ~term:last_term x t =
      let last_index = Int64.succ t.last_index in
      let entries    = IM.add last_index (x, last_term) t.entries in
        { t with last_index; last_term; entries; }

    let last_index t = (t.last_term, t.last_index)

    let get idx t =
      try
        Some (IM.find idx t.entries)
      with Not_found -> None

    let append_many l t = match l with
        [] -> (t, None)
      | l ->
          let nonconflicting, conflict_idx =
            try
              let idx, term =
                List.find
                  (fun (idx, (_, term)) ->
                     match get idx t with
                         Some (_, term') when term <> term' -> true
                       | _ -> false)
                  l in
              let entries, _, _ = IM.split idx t.entries in
                (entries, Some idx)
            with Not_found ->
              (t.entries, None)
          in
            let entries =
              List.fold_left
                (fun m (idx, (x, term)) -> IM.add idx (x, term) m)
                nonconflicting l in
            let last_index, last_term =
              try
                let idx, (_, term) = IM.max_binding entries in
                  (idx, term)
              with _ -> t.init_index, t.init_term
            in
              ({ t with last_index; last_term; entries; }, conflict_idx)

    let get_range ~from_inclusive ~to_inclusive t =
      if from_inclusive = t.last_index &&
         to_inclusive >= t.last_index
      then
        [ from_inclusive, IM.find from_inclusive t.entries ]
      else
        let _, _, post = IM.split (Int64.pred from_inclusive) t.entries in
        let pre, _, _  = if to_inclusive = Int64.max_int then (post, None, post)
                         else IM.split (Int64.succ to_inclusive) post
        in
          IM.bindings pre

    let get_term idx t =
      if t.last_index = idx then
        Some t.last_term
      else
        try
          Some (snd (IM.find idx t.entries))
        with Not_found ->
          if idx = t.init_index then Some t.init_term else None
  end

  type 'a state =
      {
        (* persistent *)
        current_term : term;
        voted_for    : rep_id option;
        log          : 'a entry LOG.t;
        id           : rep_id;
        config       : CONFIG.t;

        (* volatile *)
        state        : status;
        commit_index : index;
        last_applied : index;

        leader_id : rep_id option;

        (* new configuration we're transitioning to *)
        config' : rep_id array option;

        (* volatile on leaders *)
        next_index  : index RM.t;
        match_index : index RM.t;

        snapshot_transfers : RS.t;

        votes : RS.t;
      }

  and 'a entry = Nop | Op of 'a | Config of config

  type 'a message =
      Request_vote of request_vote
    | Vote_result of vote_result
    | Append_entries of 'a append_entries
    | Append_result of append_result

  and request_vote =
      {
        term : term;
        candidate_id : rep_id;
        last_log_index : index;
        last_log_term : term;
      }

  and vote_result =
    {
      term : term;
      vote_granted : bool;
    }

  and 'a append_entries =
    {
      term : term;
      leader_id : rep_id;
      prev_log_index : index;
      prev_log_term : term;
      entries : (index * ('a entry * term)) list;
      leader_commit : index;
    }

  and append_result =
    {
      term : term;
      result : actual_append_result;
    }

  and actual_append_result =
      Append_success of index (* last log entry included in msg we respond to *)
    | Append_failure of index (* index of log entry preceding those in
                                 message we respond to *)

  type 'a action =
      Apply of (index * 'a * term) list
    | Become_candidate
    | Become_follower of rep_id option
    | Become_leader
    | Changed_config
    | Redirect of rep_id option * 'a
    | Reset_election_timeout
    | Reset_heartbeat
    | Send of rep_id * 'a message
    | Send_snapshot of rep_id * index * config
    | Stop
end

include Kernel

let quorum_of_config config = Array.length config / 2 + 1
let quorum_of_peers peers   = (1 + Array.length peers) / 2 + 1

let vote_result s vote_granted =
  Vote_result { term = s.current_term; vote_granted; }

let append_result s result = Append_result { term = s.current_term; result }

let append_ok ~last_log_index s =
  append_result s (Append_success last_log_index)

let append_fail ~prev_log_index s =
  append_result s (Append_failure prev_log_index)

let update_commit_index s =
  (* Find last N such that log[N].term = current term AND
   * a majority of peers has got  match_index[peer] >= N. *)
  (* We require majorities in both the old and the new configutation during
   * the joint consensus. *)

  let get_match_index id =
    if id = s.id then LOG.last_index s.log |> snd
    else try RM.find id s.match_index with Not_found -> 0L in

  let i = CONFIG.quorum_min get_match_index s.config in

  (* i is the largest N such that at least half of the peers have
   * match_Index[peer] >= N; we have to enforce the other restriction:
   * log[N].term = current *)
  let commit_index' =
    match LOG.get_term i s.log with
      | Some term when term = s.current_term -> i
      | _ -> s.commit_index in

  (* increate monotonically *)
  let commit_index = max s.commit_index commit_index' in
    if commit_index = s.commit_index then s
    else { s with commit_index }

let try_commit s =
  let prev    = s.last_applied in
    if prev = s.commit_index then
      (s, [])
    else
      let s       = { s with last_applied = s.commit_index } in
      let entries = LOG.get_range
                      ~from_inclusive:(Int64.succ prev)
                      ~to_inclusive:s.commit_index
                      s.log in
      let ops     = List.filter_map
                      (function
                           (index, (Op x, term)) -> Some (index, x, term)
                         | (_, ((Nop | Config _), _)) -> None)
                      entries in

      let config, wanted_config = CONFIG.commit s.commit_index s.config in
      let changed_config        = List.exists
                                    (function (_, (Config _, _)) -> true | _ -> false)
                                    entries in
      (* if we're the leader and wanted_config = Some conf,
       * add a new log entry for the wanted configuration [conf]; it will be
       * replicated on the next heartbeat *)
      let s       = match wanted_config, s.state with
                      | Some (c, passive), Leader ->
                          let log = LOG.append ~term:s.current_term
                                      (Config (Simple_config (c, passive))) s.log
                          in
                            { s with log; config }
                      | _ -> { s with config } in
      let actions = match ops with [] -> [] | l -> [Apply ops] in
      (* "In Raft the leader steps down immediately after committing a
       * configuration entry that does not include itself." *)
      let actions = if CONFIG.mem s.id s.config then actions
                    else actions @ [Stop] in
      let actions = if changed_config then Changed_config :: actions
                    else actions
      in
        (s, actions)

let heartbeat s =
  let prev_log_term, prev_log_index = LOG.last_index s.log in
    Append_entries { term = s.current_term; leader_id = s.id;
                     prev_log_term; prev_log_index; entries = [];
                     leader_commit = s.commit_index }

type 'a send_entries =
    Snapshot | Send_entries of 'a | Snapshot_in_progress

let send_entries s from =
  match LOG.get_term (Int64.pred from) s.log with
      None -> None
    | Some prev_log_term ->
        Some
          (Append_entries
            { prev_log_term;
              term           = s.current_term;
              leader_id      = s.id;
              prev_log_index = Int64.pred from;
              entries        = LOG.get_range
                                 ~from_inclusive:from
                                 ~to_inclusive:Int64.max_int
                                 s.log;
              leader_commit  = s.commit_index;
            })

let send_entries_or_snapshot s peer from =
  if RS.mem peer s.snapshot_transfers then
    Snapshot_in_progress
  else
    match send_entries s from with
        None -> Snapshot
      | Some x -> Send_entries x

let broadcast s msg = CONFIG.peers s.config |> List.map (fun p -> Send (p, msg))

let receive_msg s peer = function
  (* Reject vote requests/results and Append_entries (which should not be
   * received anyway since passive members cannot become leaders) from passive
   * members *)
  | Append_entries _
  | Request_vote _ | Vote_result _ when not (CONFIG.mem_active peer s.config) ->
      (s, [])

  (* " If a server receives a request with a stale term number, it rejects the
   * request." *)
  | Request_vote { term; _ } when term < s.current_term ->
      (s, [Send (peer, vote_result s false)])

  (* "Current terms are exchanged whenever servers communicate; if one
   * server’s current term is smaller than the other, then it updates its
   * current term to the larger value. If a candidate or leader discovers that
   * its term is out of date, it immediately reverts to follower state."
   * *)
  | Vote_result { term; _ }
  | Append_result { term; _ } when term > s.current_term ->
      let s = { s with current_term = term;
                       voted_for    = None;
                       state        = Follower }
      in (s, [Become_follower None])

  | Request_vote { term; candidate_id; last_log_index; last_log_term; }
      when term > s.current_term ->
      let s = { s with current_term = term;
                       voted_for    = None;
                       state        = Follower;
              }
      in
        (* "If votedFor is null or candidateId, and candidate's log is at
         * least as up-to-date as receiver’s log, grant vote"
         *
         * [voted_for] is None since it was reset above when we updated
         * [current_term]
         *
         * "Raft determines which of two logs is more up-to-date
         * by comparing the index and term of the last entries in the
         * logs. If the logs have last entries with different terms, then
         * the log with the later term is more up-to-date. If the logs
         * end with the same term, then whichever log is longer is
         * more up-to-date."
         * *)
        if (last_log_term, last_log_index) < LOG.last_index s.log then
          (s, [Become_follower None; Send (peer, vote_result s false)])
        else
          let s = { s with voted_for = Some candidate_id } in
            (s, [Become_follower None; Send (peer, vote_result s true)])

  | Request_vote { term; candidate_id; last_log_index; last_log_term; } -> begin
      (* case term = current_term *)
      match s.state, s.voted_for with
          _, Some candidate when candidate <> candidate_id ->
            (s, [Send (peer, vote_result s false)])
        | (Candidate | Leader), _ ->
            (s, [Send (peer, vote_result s false)])
        | Follower, _ (* None or Some candidate equal to candidate_id *) ->
            (* "If votedFor is null or candidateId, and candidate's log is at
             * least as up-to-date as receiver’s log, grant vote"
             *
             * "Raft determines which of two logs is more up-to-date
             * by comparing the index and term of the last entries in the
             * logs. If the logs have last entries with different terms, then
             * the log with the later term is more up-to-date. If the logs
             * end with the same term, then whichever log is longer is
             * more up-to-date."
             * *)
            if (last_log_term, last_log_index) < LOG.last_index s.log then
              (s, [Send (peer, vote_result s false)])
            else
              let s = { s with voted_for = Some candidate_id } in
                (s, [Send (peer, vote_result s true)])
    end

  (* " If a server receives a request with a stale term number, it rejects the
   * request." *)
  | Append_entries { term; prev_log_index; _ } when term < s.current_term ->
      (s, [Send (peer, append_fail ~prev_log_index s)])
  | Append_entries
      { term; prev_log_index; prev_log_term; entries; leader_commit; } -> begin
        (* "Current terms are exchanged whenever servers communicate; if one
         * server’s current term is smaller than the other, then it updates
         * its current term to the larger value. If a candidate or leader
         * discovers that its term is out of date, it immediately reverts to
         * follower state." *)
        let s, actions =
          if term > s.current_term || s.state = Candidate then
            let s = { s with current_term = term;
                             state        = Follower;
                             leader_id    = Some peer;
                             (* set voted_for so that no other candidates are
                              * accepted during the new term *)
                             voted_for    = Some peer;
                    }
            in
              (s, [Become_follower (Some peer)])
          else (* term = s.current_term && s.state <> Candidate *)
            (s, [Reset_election_timeout]) in

        (* "Reply false if log doesn’t contain an entry at prevLogIndex
         * whose term matches prevLogTerm" *)
        (* In the presence of snapshots, prev_log_index might refer to a log
         * entry that was removed (subsumed by the snapshot), in which case
         * we must use as prev_log_index the index of the latest entry in
         * the snapshot (equal to the init_index of the log), and as
         * prev_log_term the term of the corresponding entry in the
         * Append_entries message. *)
        let prev_log_index, prev_log_term, entries =
          if prev_log_index >= LOG.prev_log_index s.log then
            (prev_log_index, prev_log_term, entries)
          else
            try
              let prev_idx  = LOG.prev_log_index s.log in
              let prev_term = List.assoc prev_idx entries |> snd in
              let entries   = List.drop_while
                                (fun (idx', _) -> idx' <= prev_idx) entries
              in
                (prev_idx, prev_term, entries)
            with _ -> (prev_log_index, prev_log_term, entries)
        in
          match LOG.get_term prev_log_index s.log  with
              None ->
                (* we don't have the entry at prev_log_index; we use the last
                 * entry we do have as the prev_log_index in the failure msg,
                 * thus allowing to rewind next_index in the leader quickly *)
                let prev_log_index = LOG.last_index s.log |> snd in
                  (s, Send (peer, append_fail ~prev_log_index s) :: actions)
            | Some term' when prev_log_term <> term' ->
                (s, Send (peer, append_fail ~prev_log_index s) :: actions)
            | _ ->
                let log, c_idx   = LOG.append_many entries s.log in
                let config       = match c_idx with
                                     | None -> s.config
                                     | Some idx ->
                                         CONFIG.drop ~at_or_after:idx s.config in
                let last_index   = snd (LOG.last_index log) in
                let commit_index = if leader_commit > s.commit_index then
                                     min leader_commit last_index
                                   else s.commit_index in
                let reply        = append_ok ~last_log_index:last_index s in
                let s            = { s with commit_index; log; config;
                                            leader_id = Some peer; } in
                let s, commits   = try_commit s in
                let actions      = List.concat
                                     [ [Send (peer, reply)];
                                       commits;
                                       actions ]
                in
                  (s, actions)
      end

  | Vote_result { term; _ } when term < s.current_term ->
      (s, [])
  | Vote_result { term; vote_granted; } when s.state <> Candidate ->
      (s, [])
  | Vote_result { term; vote_granted; } ->
      if not vote_granted then
        (s, [])
      else
        (* "If votes received from majority of servers: become leader" *)
        let votes = RS.add peer s.votes in
        let s     = { s with votes } in

          if not (CONFIG.has_quorum (RS.elements votes) s.config) then
            (s, [])
          else
            (* become leader! *)

            (* So as to have the leader know which entries are committed
             * (one of the 2 requirements to support read-only operations in
             * the leader, the other being making sure it's still the leader
             * with a hearbeat exchange), we have it commit a blank
             * no-op/config request entry at the start of its term, which also
             * serves as the initial heartbeat. If we're in a joint consensus,
             * we send a config request for the target configuration instead
             * of a Nop. *)
            let entry = match CONFIG.target s.config with
                          | None -> Nop
                          | Some (c, passive) -> Config (Simple_config (c, passive)) in
            let log   = LOG.append ~term:s.current_term entry s.log in

            (* With a regular (empty) hearbeat, this applies:
             *   "When a leader first comes to power, it initializes all
             *   nextIndex values to the index just after the last one in its
             *   log"
             * However, in this case we want to send the Nop too, so no Int64.succ.
             * *)
            let next_idx    = LOG.last_index log |> snd (* |> Int64.succ *) in
            let next_index  = List.fold_left
                                (fun m peer -> RM.add peer next_idx m)
                                RM.empty (CONFIG.peers s.config) in
            let match_index = List.fold_left
                                (fun m peer -> RM.add peer 0L m)
                                RM.empty (CONFIG.peers s.config) in
            let s     = { s with log; next_index; match_index;
                                 state     = Leader;
                                 leader_id = Some s.id;
                                 snapshot_transfers = RS.empty;
                        } in
            (* This heartbeat is replaced by the broadcast of the no-op
             * explained above:
             *
              (* "Upon election: send initial empty AppendEntries RPCs
               * (heartbeat) to each server; repeat during idle periods to
               * prevent election timeouts" *)
              let sends = broadcast s (heartbeat s) in
            *)
            let msg   = send_entries s next_idx in
            let sends = CONFIG.peers s.config |>
                        List.filter_map
                          (fun peer -> Option.map (fun m -> Send (peer, m)) msg)
            in
              (s, (Become_leader :: sends))

  | Append_result { term; _ } when term < s.current_term || s.state <> Leader ->
      (s, [])
  | Append_result { result = Append_success last_log_index; _ } ->
      let next_index  = RM.modify peer
                          (fun idx -> max idx (Int64.succ last_log_index))
                          s.next_index in
      let match_index = RM.modify_def
                          last_log_index peer
                          (max last_log_index) s.match_index in
      let s           = update_commit_index { s with next_index; match_index } in
      let s, actions  = try_commit s in
        (s, (Reset_election_timeout :: actions))
  | Append_result { result = Append_failure prev_log_index; _ } ->
      (* "After a rejection, the leader decrements nextIndex and retries
       * the AppendEntries RPC. Eventually nextIndex will reach a point
       * where the leader and follower logs match." *)
      let next_index = RM.modify peer
                         (fun idx -> min idx prev_log_index)
                         s.next_index in
      let s          = { s with next_index } in
      let idx        = RM.find peer next_index in
        match send_entries_or_snapshot s peer idx with
          | Snapshot ->
              (* Must send snapshot *)
              let config    = CONFIG.last_commit s.config in
              let transfers = RS.add peer s.snapshot_transfers in
              let s         = { s with snapshot_transfers = transfers } in
                (s, [Reset_election_timeout; Send_snapshot (peer, idx, config)])
          | Snapshot_in_progress -> (s, [])
          | Send_entries msg ->
              (s, [Reset_election_timeout; Send (peer, msg)])

let election_timeout s = match s.state with
    (* we have the leader step down if it does not get any append_result
     * within an election timeout *)
    Leader

  (* "If election timeout elapses without receiving AppendEntries RPC from
   * current leader or granting vote to candidate: convert to candidate" *)
  | Follower
  (* "If election timeout elapses: start new election" *)
  | Candidate ->
      (* "On conversion to candidate, start election:
       *  * Increment currentTerm
       *  * Vote for self
       *  * Reset election timeout
       *  * Send RequestVote RPCs to all other servers"
       * *)
      let s           = { s with current_term = Int64.succ s.current_term;
                                 state        = Candidate;
                                 votes        = RS.singleton s.id;
                                 leader_id    = None;
                                 voted_for    = Some s.id;
                        } in
      let term_, idx_ = LOG.last_index s.log in
      let msg         = Request_vote
                          {
                            term = s.current_term;
                            candidate_id = s.id;
                            last_log_index = idx_;
                            last_log_term = term_;
                          } in
      let sends       = broadcast s msg in
        (s, (Become_candidate :: sends))

let heartbeat_timeout s = match s.state with
    Follower | Candidate -> (s, [])
  | Leader ->
      let s, sends =
        CONFIG.peers s.config |>
        List.fold_left
          (fun (s, sends) peer ->
             let idx = RM.find peer s.next_index in
               match
                 send_entries_or_snapshot s peer idx
               with
                   Snapshot_in_progress -> (s, sends)
                 | Send_entries msg -> (s, Send (peer, msg) :: sends)
                 | Snapshot ->
                     (* must send snapshot if cannot send log *)
                     let transfers = RS.add peer s.snapshot_transfers in
                     let s         = { s with snapshot_transfers = transfers } in
                     let config    = CONFIG.last_commit s.config in
                       (s, Send_snapshot (peer, idx, config) :: sends))
          (s, [])
      in
        (s, (Reset_heartbeat :: sends))

let client_command x s = match s.state with
    Follower | Candidate -> (s, [Redirect (s.leader_id, x)])
  | Leader ->
      let log        = LOG.append ~term:s.current_term (Op x) s.log in
      let s, actions =
        CONFIG.peers s.config |>
        List.fold_left
          (fun (s, actions) peer ->
             let idx = RM.find peer s.next_index in
               match send_entries_or_snapshot s peer idx with
                   Snapshot ->
                     (* must send snapshot if cannot send log *)
                     let transfers = RS.add peer s.snapshot_transfers in
                     let s         = { s with snapshot_transfers = transfers } in
                     let config    = CONFIG.last_commit s.config in
                       (s, Send_snapshot (peer, idx, config) :: actions)
                 | Snapshot_in_progress -> (s, actions)
                 | Send_entries msg -> (s, Send (peer, msg) :: actions))
          ({ s with log }, []) in
      let actions = match actions with
                      | [] -> []
                      | l -> Reset_heartbeat :: actions
      in
        (s, actions)

let install_snapshot ~last_term ~last_index ~config s = match s.state with
    Leader | Candidate -> (s, false)
  | Follower ->
      let config = CONFIG.make ~node_id:s.id config in
      let log    =
        match LOG.get_term last_index s.log with
            (* "If the follower has an entry that matches the snapshot’s last
             * included index and term, then there is no conflict: it removes only
             * the prefix of its log that the snapshot replaces.  Otherwise, the
             * follower removes its entire log; it is all superseded by the
             * snapshot."
             * *)
            Some t when t = last_term -> LOG.trim_prefix ~last_index ~last_term s.log
          | _ -> LOG.empty ~init_index:last_index ~init_term:last_term in

      let s = { s with log; config;
                       last_applied = last_index;
                       commit_index = last_index;
              }
      in
        (s, true)

let snapshot_sent peer ~last_index s = match s.state with
    Follower | Candidate -> (s, [])
  | Leader ->
      let transfers  = RS.remove peer s.snapshot_transfers in
      let next_index = RM.modify peer
                         (fun idx -> max idx (Int64.succ last_index))
                         s.next_index in
      let s          = { s with snapshot_transfers = transfers; next_index } in
        match send_entries s (RM.find peer s.next_index) with
            None -> (s, [])
          | Some msg -> (s, [Send (peer, msg)])

let snapshot_send_failed peer s =
  let s = { s with snapshot_transfers = RS.remove peer s.snapshot_transfers } in
    (s, [])

let compact_log last_index s = match s.state with
  | Follower | Candidate -> s
  | Leader ->
      if not (RS.is_empty s.snapshot_transfers) then s
      else
        match LOG.get_term last_index s.log with
            None -> s
          | Some last_term ->
              let log = LOG.trim_prefix ~last_index ~last_term s.log in
                { s with log }

let config_eq c1 c2 =
  List.sort String.compare c1 = List.sort String.compare c2

let change_config ?passive c2 s = match s.state with
      Follower -> `Redirect s.leader_id
    | Candidate -> `Redirect None
    | Leader ->
        match
          CONFIG.join (LOG.last_index s.log |> snd |> Int64.succ) ?passive c2 s.config
        with
            None -> `Change_in_process
          | Some (config, target) ->
              match CONFIG.last_commit s.config with
                | Simple_config (c, p)
                    when config_eq c c2 && config_eq p (Option.default p passive) ->
                    `Already_changed
                | _ ->
                    let log    = LOG.append ~term:s.current_term (Config target) s.log in
                    let s      = { s with config; log } in
                      `Start_change s

module Types = Kernel

module Core =
struct
  include Types

  let make ~id ~current_term ~voted_for ~log ~config () =
    let log    = LOG.of_list ~init_index:0L ~init_term:current_term log in
    let config = CONFIG.make ~node_id:id config in
      {
        current_term; voted_for; log; id; config;
        state        = Follower;
        commit_index = 0L;
        last_applied = 0L;
        leader_id    = None;
        config'      = None;
        next_index   = RM.empty;
        match_index  = RM.empty;
        votes        = RS.empty;
        snapshot_transfers = RS.empty;
      }

  let leader_id (s : _ state) = s.leader_id

  let id s     = s.id
  let status s = s.state
  let config s = CONFIG.current s.config
  let last_index s = snd (LOG.last_index s.log)
  let last_term s  = fst (LOG.last_index s.log)
  let peers s      = CONFIG.peers s.config

  let receive_msg       = receive_msg
  let election_timeout  = election_timeout
  let heartbeat_timeout = heartbeat_timeout
  let client_command    = client_command
  let install_snapshot  = install_snapshot
  let snapshot_sent     = snapshot_sent
  let compact_log       = compact_log
  let snapshot_send_failed = snapshot_send_failed
  let change_config     = change_config
end
