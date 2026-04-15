import 'package:http/http.dart' as http;

void main() async {
  final url1 = 'https://www.instagram.com/reel/DVJ6SqkEQPr/?igsh=bXVibGg4c29xbmxl';
  final embedUrl1 = 'https://www.instagram.com/p/DVJ6SqkEQPr/embed/captioned/';
  
  final resPost = await http.get(Uri.parse(url1));
  final resEmbed = await http.get(Uri.parse(embedUrl1));
  
  final combined = resPost.body + resEmbed.body;
  
  // Views
  final viewRegex = RegExp(r'[\\"]+video_view_count[\\":\s]+(\d+)');
  print("Views matches:");
  for (var m in viewRegex.allMatches(combined)) {
    print(m.group(1));
  }
  
  // Meta description
  final metaDesc = RegExp(r'content="([^"]+ likes[^"]+)"');
  print("Meta description:");
  print(metaDesc.firstMatch(combined)?.group(1));

  final likeRegex = RegExp(r'[\\"]+edge_media_preview_like[\\":\s\{]+count[\\":\s]+(\d+)');
  print("Likes matches JSON:");
  for (var m in likeRegex.allMatches(combined)) {
    print(m.group(1));
  }
}
