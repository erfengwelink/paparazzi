(*
 * XML preprocessing for periodic messages
 *
 * Copyright (C) 2003 Pascal Brisset, Antoine Drouin
 *
 * This file is part of paparazzi.
 *
 * paparazzi is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2, or (at your option)
 * any later version.
 *
 * paparazzi is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with paparazzi; see the file COPYING.  If not, write to
 * the Free Software Foundation, 59 Temple Place - Suite 330,
 * Boston, MA 02111-1307, USA.
 *
 *)

open Printf
module GC = Gen_common

let (//) = Filename.concat

let margin = ref 0
let step = 2

let right () = margin := !margin + step
let left () = margin := !margin - step

let lprintf = fun c f ->
  fprintf c "%s" (String.make !margin ' ');
  fprintf c f

let output_modes = fun out_h process_name telem_type modes freq ->
  let min_period = 1./.float freq in
  let max_period = 65536. /. float freq in

  (** For each mode in this process *)
  List.iter
    (fun mode ->
      let mode_name = ExtXml.attrib mode "name" in
      lprintf out_h "if (telemetry_mode_%s == TELEMETRY_MODE_%s_%s) {\n" process_name process_name mode_name;
      right ();

      (** Computes the required modulos *)
      let messages = List.map (fun x ->
        let p = float_of_string (ExtXml.attrib x "period") in
        if p < min_period || p > max_period then
          fprintf stderr "Warning: period is bound between %.3fs and %.3fs for message %s\n%!" min_period max_period (ExtXml.attrib x "name");
        (x, min 65535 (max 1 (int_of_float (p*.float_of_int freq))))
      ) (Xml.children mode) in
      let modulos = GC.singletonize (List.map snd messages) in
      List.iter (fun m ->
        let v = sprintf "i%d" m in
        let _type = if m >= 256 then "uint16_t" else "uint8_t" in
        lprintf out_h "static %s %s = 0; %s++; if (%s>=%d) %s=0;\n" _type v v v m v;
      ) modulos;

      (* create var to loop trough callbacks if needed *)
      if (List.length messages > 0) then
        lprintf out_h "uint8_t j;\n";

      (** For each message in this mode *)
      let messages = List.sort (fun (_,p) (_,p') -> compare p p') messages in
      let i = ref 0 in (** Basic balancing:1 message every 10Hz *)
      let phase = ref 0 in
      let l = ref [] in
      List.iter
        (fun (message, p) ->
          let message_name = ExtXml.attrib message "name" in
          i := !i mod p;
          (* if phase attribute is present, use it, otherwise shedule at 10Hz *)
          let message_phase = try int_of_float (float_of_string (ExtXml.attrib message "phase")*.float_of_int freq) with _ -> !i in
          phase := message_phase;
          let else_ = if List.mem_assoc p !l && not (List.mem (p, !phase) !l) then "else " else "" in
          lprintf out_h "%sif (i%d == %d) {\n" else_ p !phase;
          l := (p, !phase) :: !l;
          i := !i + freq/10;
          right ();
          lprintf out_h "for (j = 0; j < TELEMETRY_NB_CBS; j++) {\n";
          right ();
          lprintf out_h "if (telemetry->cbs[TELEMETRY_%s_MSG_%s_IDX].slots[j] != NULL)\n" telem_type message_name;
          right ();
          lprintf out_h "telemetry->cbs[TELEMETRY_%s_MSG_%s_IDX].slots[j](trans, dev);\n" telem_type message_name;
          left ();
          lprintf out_h "else break;\n";
          left ();
          lprintf out_h "}\n";
          fprintf out_h "#if USE_PERIODIC_TELEMETRY_REPORT\n";
          lprintf out_h "if (j == 0) periodic_telemetry_err_report(TELEMETRY_PROCESS_%s, telemetry_mode_%s, %s_MSG_ID_%s);\n" process_name process_name telem_type message_name;
          fprintf out_h "#endif\n";
          left ();
          lprintf out_h "}\n"
        )
        (List.rev messages);
      left ();
      lprintf out_h "}\n")
    modes

let write_settings = fun xml_file out_set telemetry_xml ->
  (* filter xml file to remove unneeded process and modes (more than 1 mode per process) *)
  let filtered_xml = List.filter (fun p -> List.length (Xml.children p) > 1) (Xml.children telemetry_xml) in
  fprintf out_set "<!-- This file has been generated by gen_periodic from %s -->\n" xml_file;
  fprintf out_set "<!-- Version %s -->\n" (Env.get_paparazzi_version ());
  fprintf out_set "<!-- Please DO NOT EDIT -->\n\n";
  fprintf out_set "<settings>\n";
  if List.length filtered_xml > 0 then begin
    fprintf out_set " <dl_settings>\n";
    fprintf out_set "  <dl_settings name=\"Telemetry\">\n";
    List.iter (fun p ->
      (* for each (pre-filtered) process *)
      let process_name = Xml.attrib p "name" in
      (* convert the xml list of mode to a string list *)
      let modes = List.map (fun m -> Xml.attrib m "name") (Xml.children p) in
      let nb_modes = List.length modes in
      match nb_modes with
      | 0 | 1 -> () (* Nothing to do if 1 or zero mode *)
      | _ -> (* add settings with all modes *)
          fprintf out_set "   <dl_setting min=\"0\" step=\"1\" max=\"%d\" var=\"telemetry_mode_%s\" shortname=\"%s\" values=\"%s\" module=\"generated/periodic_telemetry\">\n" (nb_modes-1) process_name process_name (String.concat "|" modes);
          let i = ref 0 in
          List.iter (fun m -> try
            let key = Xml.attrib m "key_press" in
            fprintf out_set "    <key_press key=%S value=%S/>\n" key (string_of_int !i);
            incr i
          with _ -> incr i) (Xml.children p);
          fprintf out_set "   </dl_setting>\n"
      ) filtered_xml;
    fprintf out_set "  </dl_settings>\n";
    fprintf out_set " </dl_settings>\n";
  end;
  fprintf out_set "</settings>\n"

let print_message_table = fun out_h xml ->
  let telemetry_types = Hashtbl.create 2 in
  (* For each process *)
  List.iter (fun process ->
    let telem_type = Compat.uppercase_ascii (ExtXml.attrib_or_default process "type" "pprz") in
    if not (Hashtbl.mem telemetry_types telem_type) then Hashtbl.add telemetry_types telem_type (Hashtbl.create 15);
    let messages = Hashtbl.find telemetry_types telem_type in
    (** For each mode of this process *)
    List.iter (fun mode ->
      (** For each message in this mode *)
      List.iter (fun msg ->
        let n = ExtXml.attrib msg "name" in
        (* Add message to the list if it doesn't exist *)
        if not (Hashtbl.mem messages n) then Hashtbl.add messages n ()
      ) (Xml.children mode)
    ) (Xml.children process)
  ) (Xml.children xml);
  (* for each telemetry type, print ID and other defines *)
  Hashtbl.iter (fun telem_type messages ->
    (* Print ID *)
    fprintf out_h "/* Periodic telemetry messages of type %s */\n" telem_type;
    let nb = Hashtbl.fold (fun n _ i ->
      Xml2h.define (sprintf "TELEMETRY_%s_MSG_%s_IDX" telem_type n) (sprintf "%d" i);
      i+1
    ) messages 0 in
    fprintf out_h "#define TELEMETRY_%s_NB_MSG %d\n" telem_type nb;
    (* Structure initialization *)
    fprintf out_h "\n#define TELEMETRY_%s_MSG_NAMES { \\\n" telem_type;
    Hashtbl.iter (fun n _ -> fprintf out_h "  \"%s\", \\\n" n) messages;
    fprintf out_h "}\n\n";
    fprintf out_h "#define TELEMETRY_%s_CBS { \\\n" telem_type;
    Hashtbl.iter (fun n _ -> fprintf out_h "  {.id=%s_MSG_ID_%s, .slots={ NULL }}, \\\n" telem_type n) messages;
    fprintf out_h "}\n\n"
  ) telemetry_types

let print_process_send = fun out_h xml freq ->
  (** For each process *)
  List.iter
    (fun process ->
      let process_name = ExtXml.attrib process "name" in
      let telem_type = Compat.uppercase_ascii (ExtXml.attrib_or_default process "type" "pprz") in
      let modes = Xml.children process in

      fprintf out_h "\n/* Periodic telemetry (type %s): %s process */\n" telem_type process_name;
      let p_id = ref 0 in
      Xml2h.define (sprintf "TELEMETRY_PROCESS_%s" process_name) (string_of_int !p_id);
      incr p_id;

      (** For each mode of this process *)
      let _ = List.fold_left (fun i mode ->
        let name = ExtXml.attrib mode "name" in
        Xml2h.define (sprintf "TELEMETRY_MODE_%s_%s" process_name name) (string_of_int i);
        (* Output the periods of the messages *)
        List.iter (fun x ->
          let p = ExtXml.attrib x "period"
          and n = ExtXml.attrib x "name" in
          (* FIXME really needed ? *)
          Xml2h.define (sprintf "PERIOD_%s_%s_%d" n process_name i) (sprintf "(%s)" p)
        ) (Xml.children mode);
        i + 1
      ) 0 modes in

      fprintf out_h "\n/* Functions for %s process */\n" process_name;
      fprintf out_h "#ifdef PERIODIC_C_%s\n" (Compat.uppercase_ascii process_name);
      fprintf out_h "#ifndef TELEMETRY_MODE_%s\n" (Compat.uppercase_ascii process_name);
      fprintf out_h "#define TELEMETRY_MODE_%s 0\n" (Compat.uppercase_ascii process_name);
      fprintf out_h "#endif\n";
      fprintf out_h "uint8_t telemetry_mode_%s = TELEMETRY_MODE_%s;\n" process_name (Compat.uppercase_ascii process_name);
      fprintf out_h "#else /* PERIODIC_C_%s not defined (general header) */\n" (Compat.uppercase_ascii process_name);
      fprintf out_h "extern uint8_t telemetry_mode_%s;\n" process_name;
      fprintf out_h "#endif /* PERIODIC_C_%s */\n" (Compat.uppercase_ascii process_name);

      lprintf out_h "static inline void periodic_telemetry_send_%s(struct periodic_telemetry *telemetry, struct transport_tx *trans, struct link_device *dev) {  /* %dHz */\n" process_name freq;
      right ();
      output_modes out_h process_name telem_type modes freq;
      left ();
      lprintf out_h "}\n"
    )
    (Xml.children xml)



let _ =
  if Array.length Sys.argv <> 5 then begin
    failwith (sprintf "Usage: %s <messages.xml> <telemetry.xml> frequency_in_hz out_settings_file" Sys.argv.(0))
  end;

  let freq = int_of_string(Sys.argv.(3)) in
  let telemetry_xml =
    try
      Xml.parse_file Sys.argv.(2)
    with Dtd.Check_error e -> failwith (Dtd.check_error e)
  in

  let out_h = stdout in

  (** Print header *)
  fprintf out_h "/* This file has been generated by gen_periodic from %s and %s */\n" Sys.argv.(1) Sys.argv.(2);
  fprintf out_h "/* Version %s */\n" (Env.get_paparazzi_version ());
  fprintf out_h "/* Please DO NOT EDIT */\n\n";
  fprintf out_h "#ifndef _VAR_PERIODIC_H_\n";
  fprintf out_h "#define _VAR_PERIODIC_H_\n\n";
  fprintf out_h "#include \"std.h\"\n";
  fprintf out_h "#include \"generated/airframe.h\"\n";
  fprintf out_h "#include \"subsystems/datalink/telemetry_common.h\"\n\n";
  fprintf out_h "#define TELEMETRY_FREQUENCY %d\n\n" freq;

  (** Print the telemetry table with ID *)
  print_message_table out_h telemetry_xml;

  (** Print process sending functions *)
  print_process_send out_h telemetry_xml freq;

  (** Output XML settings file with telemetry modes *)
  let out_set = open_out Sys.argv.(4) in
  write_settings Sys.argv.(2) out_set telemetry_xml;
  close_out out_set;

  fprintf out_h "#endif // _VAR_PERIODIC_H_\n";

