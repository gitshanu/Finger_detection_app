# Finger Capture Quality Check App (Flutter)

A Flutter-based mobile application that captures finger images using the device camera and provides real-time guidance for correct finger placement. The app performs basic image quality validation and displays an overall quality score with detailed indicators before accepting the captured image.

## ✅ Features
- Live camera preview using Flutter Camera plugin
- Real-time finger positioning guidance using a circular overlay
  - ✅ Green circle = finger positioned correctly
  - ❌ Red circle = finger not in position
- Captures **only the finger region** (cropped center area)
- Basic image quality checks after capture:
  - Focus / Blur score
  - Illumination check
  - Finger coverage validation
- Displays:
  - Overall Quality Score (0–100)
  - Pass/Fail result
  - Individual quality indicators with status

## 🛠 Tech Stack
- **Flutter**
- **Dart**
- `camera` package (live preview & capture)
- `permission_handler` (camera permission)
- `image` package (image processing, cropping, scoring)

## 📌 How It Works
1. User opens camera screen.
2. App shows a circular guide overlay.
3. When the finger is correctly placed, the circle turns green.
4. On capture, the app:
   - crops only the finger area
   - runs quality checks
   - shows a quality report (score + pass/fail)
5. User can retake or accept the image.

## ▶️ Run Locally
```bash
flutter pub get
flutter run
