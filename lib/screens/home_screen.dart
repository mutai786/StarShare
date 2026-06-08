import 'package:flutter/material.dart';
import 'package:flutter/material.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,

      appBar: AppBar(
        title: const Text("StarShare"),
        backgroundColor: Colors.blueAccent,
        actions: const [
          Icon(Icons.notifications),
          SizedBox(width: 10),
          Icon(Icons.person),
          SizedBox(width: 10),
        ],
      ),

      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            const Text(
              "Good Afternoon 👋",
              style: TextStyle(
                fontSize: 24,
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 8),

            const Text(
              "Your files are secured with end-to-end encryption 🔐",
              style: TextStyle(
                color: Colors.grey,
                fontSize: 14,
              ),
            ),

            const SizedBox(height: 25),

            Row(
              children: [
                Expanded(
                  child: _statCard(
                    Icons.send,
                    "Sent",
                    "24",
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _statCard(
                    Icons.download,
                    "Received",
                    "18",
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: _statCard(
                    Icons.storage,
                    "Storage",
                    "2.1 GB",
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _statCard(
                    Icons.lock,
                    "Secure",
                    "Active",
                  ),
                ),
              ],
            ),

            const SizedBox(height: 25),

            const Text(
              "Quick Actions",
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 15),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [

                _actionButton(
                  context,
                  Icons.upload_file,
                  "Send",
                      () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const SendFileScreen(),
                      ),
                    );
                  },
                ),

                _actionButton(
                  context,
                  Icons.download,
                  "Receive",
                      () {},
                ),

                _actionButton(
                  context,
                  Icons.qr_code_scanner,
                  "QR",
                      () {},
                ),

                _actionButton(
                  context,
                  Icons.chat,
                  "Chat",
                      () {},
                ),
              ],
            ),

            const SizedBox(height: 25),

            const Text(
              "Recent Files",
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 10),

            Card(
              color: Colors.white10,
              child: ListTile(
                leading: Icon(
                  Icons.picture_as_pdf,
                  color: Colors.red,
                ),
                title: Text(
                  "Project.pdf",
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  "Sent 2 min ago",
                  style: TextStyle(color: Colors.grey),
                ),
                trailing: Icon(
                  Icons.check_circle,
                  color: Colors.green,
                ),
              ),
            ),

            Card(
              color: Colors.white10,
              child: ListTile(
                leading: Icon(
                  Icons.image,
                  color: Colors.blue,
                ),
                title: Text(
                  "Vacation.jpg",
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  "Received 1 hr ago",
                  style: TextStyle(color: Colors.grey),
                ),
                trailing: Icon(
                  Icons.download_done,
                  color: Colors.green,
                ),
              ),
            ),
          ],
        ),
      ),

      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.greenAccent,
        child: const Icon(Icons.add),
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const SendFileScreen(),
            ),
          );
        },
      ),
    );
  }

  Widget _statCard(IconData icon, String title, String value) {
    return Card(
      color: Colors.white10,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, color: Colors.greenAccent, size: 30),
            const SizedBox(height: 10),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              title,
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionButton(
      BuildContext context,
      IconData icon,
      String label,
      VoidCallback onTap,
      ) {
    return Column(
      children: [
        CircleAvatar(
          radius: 28,
          backgroundColor: Colors.blueAccent,
          child: IconButton(
            icon: Icon(icon, color: Colors.white),
            onPressed: onTap,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          label,
          style: const TextStyle(color: Colors.white),
        ),
      ],
    );
  }
}

class SendFileScreen extends StatefulWidget {
  const SendFileScreen({super.key});

  @override
  State<SendFileScreen> createState() => _SendFileScreenState();
}

class _SendFileScreenState extends State<SendFileScreen> {
  String? fileName;
  bool isEncrypted = false;

  void pickFile() {
    // MOCK FILE PICK (no Firebase yet)
    setState(() {
      fileName = "Project.pdf";
      isEncrypted = false;
    });
  }

  void encryptFile() {
    setState(() {
      isEncrypted = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("File Encrypted 🔐")),
    );
  }

  void sendFile() {
    if (fileName == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No file selected")),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("File Sent Successfully 📤")),
    );

    setState(() {
      fileName = null;
      isEncrypted = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,

      appBar: AppBar(
        title: const Text("Send File"),
        backgroundColor: Colors.blueAccent,
      ),

      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            const Text(
              "Select a file to share",
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),

            const SizedBox(height: 20),

            // FILE DISPLAY CARD
            Card(
              color: Colors.white10,
              child: ListTile(
                leading: const Icon(Icons.insert_drive_file,
                    color: Colors.greenAccent),
                title: Text(
                  fileName ?? "No file selected",
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  isEncrypted ? "Encrypted 🔐" : "Not encrypted",
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
            ),

            const SizedBox(height: 20),

            // PICK FILE BUTTON
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: pickFile,
                icon: const Icon(Icons.attach_file),
                label: const Text("Pick File"),
              ),
            ),

            const SizedBox(height: 10),

            // ENCRYPT BUTTON
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: fileName == null ? null : encryptFile,
                icon: const Icon(Icons.lock),
                label: const Text("Encrypt File"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                ),
              ),
            ),

            const SizedBox(height: 10),

            // SEND BUTTON
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: fileName == null ? null : sendFile,
                icon: const Icon(Icons.send),
                label: const Text("Send File"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}