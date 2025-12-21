import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'auth_screens.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final PageController _controller = PageController();
  int _currentPage = 0;

  final List<Map<String, String>> _pages = [
    {
      "title": "Welcome to PillPal",
      "desc": "Your smart companion for medication management.",
      "icon": "medical_services",
    },
    {
      "title": "Track & Monitor",
      "desc": "Keep track of patients, alarms, and medication history easily.",
      "icon": "analytics",
    },
    {
      "title": "Kiosk Integration",
      "desc": "Seamlessly connect with the PillPal dispensing unit.",
      "icon": "wifi_tethering",
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1565C0),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _controller,
                onPageChanged: (index) => setState(() => _currentPage = index),
                itemCount: _pages.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.all(32.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(30),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            _getIconData(_pages[index]["icon"]!),
                            size: 100,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 40),
                        Text(
                          _pages[index]["title"]!,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.poppins(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 20),
                        // --- FIX IS HERE ---
                        Text(
                          _pages[index]["desc"]!,
                          textAlign: TextAlign.center, // Moved outside style
                          style: GoogleFonts.poppins(
                            fontSize: 16,
                            color: Colors.white70,
                          ),
                        ),
                        // -------------------
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                _pages.length,
                (index) => AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  margin: const EdgeInsets.symmetric(horizontal: 5),
                  height: 10,
                  width: _currentPage == index ? 20 : 10,
                  decoration: BoxDecoration(
                    color: _currentPage == index ? Colors.white : Colors.white38,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 40),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
              child: SizedBox(
                width: double.infinity,
                height: 55,
                child: ElevatedButton(
                  onPressed: () {
                    if (_currentPage == _pages.length - 1) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const AuthScreen()),
                      );
                    } else {
                      _controller.nextPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF1565C0),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child: Text(
                    _currentPage == _pages.length - 1 ? "GET STARTED" : "NEXT",
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
            if (_currentPage != _pages.length - 1)
              TextButton(
                onPressed: () {
                   Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const AuthScreen()),
                      );
                },
                child: const Text("SKIP", style: TextStyle(color: Colors.white70)),
              ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  IconData _getIconData(String name) {
    switch (name) {
      case 'medical_services':
        return Icons.medical_services_rounded;
      case 'analytics':
        return Icons.analytics_outlined;
      case 'wifi_tethering':
        return Icons.wifi_tethering;
      default:
        return Icons.circle;
    }
  }
}