import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';
import 'package:permission_handler/permission_handler.dart'; // Add this import

class CsvHelper {
  List<List<dynamic>> rows = [];

  CsvHelper() {
    rows.add(['Timestamp', 'SensorValue']);
  }

  Future<void> addRow(DateTime timestamp, double sensorValue) async {
    rows.add([timestamp.toIso8601String(), sensorValue]);
  }

  Future<File> saveCsvFile() async {
    // Request storage permission
    var status = await Permission.storage.request();
    if (!status.isGranted) {
      throw Exception("Storage permission denied");
    }

    // Get path to public Downloads folder
    final directory = Directory('/storage/emulated/0/Download');

    // Create the file
    final fileName = 'sensor_data_${DateTime.now().millisecondsSinceEpoch}.csv';
    final file = File('${directory.path}/$fileName');

    final csvData = const ListToCsvConverter().convert(rows);
    return file.writeAsString(csvData);
  }
}
