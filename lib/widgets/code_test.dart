import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:irblaster_controller/l10n/l10n.dart';
import 'package:irblaster_controller/utils/ir.dart';
import 'package:irblaster_controller/utils/ir_keep_alive.dart';

String deviceCodeString = "00 ff";
String commandString = "00 ff";
bool isBruteforcing = false;

class CodeTest extends StatefulWidget {
  final String? code;
  const CodeTest({super.key, this.code});

  @override
  CodeTestState createState() => CodeTestState();
}

void bruteforce(int n, bool send) {
  if (send) {
    final int code = int.parse(
        (deviceCodeString + commandString).replaceAll(" ", ""),
        radix: 16);
    transmit(
      code,
      info: IrSendInfo(
        label: 'NEC ${deviceCodeString.trim()} ${commandString.trim()}'
            .replaceAll(RegExp(r'\s+'), ' '),
        protocol: 'NEC',
        hex: code.toRadixString(16).toUpperCase(),
        source: 'Signal Tester',
      ),
    );
  }

  int command = int.parse(commandString.substring(0, 2), radix: 16);
  int deviceCode = int.parse(deviceCodeString.substring(0, 2), radix: 16);
  // increase command after if it's bigger than 4 bits increase device code and set command to 0 again
  command += n;
  if (command < 0) {
    command = 0;
  }
  if (command > 0xFF) {
    deviceCode++;
    command = 0;
  }
  if (deviceCode > 0xFFFF) {
    deviceCode = 0;
    isBruteforcing = false;
  }
  
  commandString =
      "${command.toRadixString(16).padLeft(2, '0')} ${(~command).toUnsigned(8).toRadixString(16).padLeft(2, '0')}";
  deviceCodeString =
      "${deviceCode.toRadixString(16).padLeft(2, '0')} ${(~deviceCode).toUnsigned(8).toRadixString(16).padLeft(2, '0')}";
}

class CodeTestState extends State<CodeTest> {
  static const String _sweepTitle = 'Signal tester running';

  Timer? timer;
  int _sent = 0;
  DateTime? _startedAt;

  @override
  void dispose() {
    _stopSweep();
    super.dispose();
  }

  @override
  void initState() {
    if (widget.code != null) {
      deviceCodeString =
          "${widget.code!.substring(0, 2)} ${widget.code!.substring(2, 4)}";
      commandString =
          "${widget.code!.substring(4, 6)} ${widget.code!.substring(6, 8)}";
    }
    super.initState();
  }

  String _currentCodeLabel() =>
      'NEC ${deviceCodeString.trim()} ${commandString.trim()}'
          .replaceAll(RegExp(r'\s+'), ' ');

  /// Start/stop the 1 s sweep. While it runs a foreground service keeps the
  /// isolate alive, so the sweep and the IR log continue in the background.
  Future<void> _toggleSweep() async {
    if (isBruteforcing) {
      _stopSweep();
      setState(() {});
      return;
    }
    isBruteforcing = true;
    _sent = 0;
    _startedAt = DateTime.now();
    setState(() {});
    await IrKeepAlive.clearStopRequest();
    await IrKeepAlive.start(
      title: _sweepTitle,
      text: '${_currentCodeLabel()} — keeps running when you leave the app',
    );
    timer?.cancel();
    timer =
        Timer.periodic(const Duration(seconds: 1), (Timer t) => _sweepTick());
  }

  void _sweepTick() {
    if (!mounted || !isBruteforcing) return;
    final label = _currentCodeLabel();
    setState(() {
      bruteforce(1, true);
    });
    _sent++;
    unawaited(_pollStopRequest());
    if (IrKeepAlive.shouldUpdate(_sent)) {
      final elapsed =
          DateTime.now().difference(_startedAt ?? DateTime.now()).inSeconds;
      unawaited(IrKeepAlive.update(
        title: _sweepTitle,
        text: '$label · $_sent sent · ${elapsed}s',
      ));
    }
  }

  /// Stops the sweep when the user taps Stop in the notification.
  Future<void> _pollStopRequest() async {
    if (!await IrKeepAlive.stopRequested) return;
    if (!mounted) return;
    _stopSweep();
    setState(() {});
  }

  void _stopSweep() {
    timer?.cancel();
    timer = null;
    isBruteforcing = false;
    unawaited(IrKeepAlive.stop());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        body: SafeArea(
            minimum: const EdgeInsets.only(top: 100),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  deviceCodeString,
                  style: const TextStyle(fontSize: 25),
                ),
                Text(context.l10n.deviceCodeLabel),
                Text(
                  commandString,
                  style: const TextStyle(fontSize: 25),
                ),
                Text(context.l10n.commandLabel),
                const Padding(padding: EdgeInsets.all(20)),
                GridView.count(
                    primary: false,
                    padding: const EdgeInsets.all(20),
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    children: [
                      IconButton(
                        onPressed: () {
                          setState(() {
                            bruteforce(-1, false);
                          });
                        },
                        icon: const Icon(Icons.arrow_left),
                        iconSize: 35,
                      ),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () {
                          setState(() {
                            bruteforce(0, true);
                          });
                        },
                        child:
                            Text(context.l10n.test, style: const TextStyle(fontSize: 25)),
                      ),
                      IconButton(
                        onPressed: () {
                          setState(() {
                            bruteforce(1, true);
                          });
                        },
                        icon: const Icon(Icons.arrow_right),
                        iconSize: 35,
                      ),
                      IconButton(
                        onPressed: () {
                          // Show a popup so the user can edit the code in text fields
                          setState(() {
                            showDialog(
                                context: context,
                                builder: (BuildContext context) {
                                  TextEditingController controller =
                                      TextEditingController();
                                  controller.text =
                                      (deviceCodeString + commandString)
                                          .replaceAll(" ", "");
                                  return AlertDialog(
                                      actions: [
                                        TextButton(
                                            onPressed: () {
                                              Navigator.pop(context);
                                            },
                                            child: Text(context.l10n.cancel)),
                                        TextButton(
                                            onPressed: () {
                                              if (controller.text.length == 8) {
                                                setState(() {
                                                  deviceCodeString =
                                                      "${controller.text.substring(0, 2)} ${controller.text.substring(2, 4)}";
                                                  commandString =
                                                      "${controller.text.substring(4, 6)} ${controller.text.substring(6, 8)}";
                                                });
                                              }
                                              Navigator.pop(context);
                                            },
                                            child: Text(context.l10n.saveAction))
                                      ],
                                      title:
                                          Text(context.l10n.editButtonCodeTitle),
                                      content: TextField(
                                        controller: controller,
                                        maxLength: 8,
                                        maxLines: 1,
                                        style: const TextStyle(fontSize: 25),
                                        textAlign: TextAlign.center,
                                        inputFormatters: [
                                          FilteringTextInputFormatter.allow(
                                              RegExp("[0-9a-fA-F]")),
                                        ],
                                      ));
                                });
                          });
                        },
                        icon: const Icon(Icons.edit),
                        iconSize: 35,
                      ),
                      IconButton(
                        onPressed: _toggleSweep,
                        icon: Icon(
                            isBruteforcing ? Icons.pause : Icons.play_arrow),
                        iconSize: 35,
                      ),
                      IconButton(
                        onPressed: () {
                          Navigator.pop(
                              context, deviceCodeString + commandString);
                        },
                        icon: const Icon(Icons.check),
                        iconSize: 35,
                      ),
                    ]),
              ],
            )));
  }
}
