#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import json
import re
from urllib.parse import urljoin
from pathlib import Path


def parse_m3u(m3u_file):
    """解析 M3U 文件并返回频道列表"""
    channels = []

    with open(m3u_file, 'r', encoding='utf-8') as f:
        lines = f.readlines()

    i = 0
    while i < len(lines):
        line = lines[i].strip()

        # 查找 #EXTINF 行
        if line.startswith('#EXTINF:'):
            # 提取频道信息
            channel_info = {}

            # 提取 tvg-name
            tvg_name_match = re.search(r'tvg-name="([^"]+)"', line)
            if tvg_name_match:
                channel_info['name'] = tvg_name_match.group(1)

            # 提取 tvg-id
            tvg_id_match = re.search(r'tvg-id="([^"]+)"', line)
            if tvg_id_match:
                channel_info['tvg-id'] = tvg_id_match.group(1)

            # 提取 group-title
            group_match = re.search(r'group-title="([^"]+)"', line)
            if group_match:
                channel_info['group'] = group_match.group(1)

            # 提取频道标题（逗号后面的部分）
            title_match = re.search(r',(.*)$', line)
            if title_match:
                channel_info['title'] = title_match.group(1).strip()

            # 读取下一行（流地址）
            i += 1
            if i < len(lines):
                stream_url = lines[i].strip()
                if stream_url and not stream_url.startswith('#'):
                    channel_info['url'] = stream_url
                    channels.append(channel_info)

        i += 1

    return channels


def build_tvbox_config(channels, epg_url):
    """构建 TVBox JSON 配置"""

    # 将频道按分组组织
    groups = {}
    for channel in channels:
        group = channel.get('group', '未分类')
        if group not in groups:
            groups[group] = []
        groups[group].append(channel)

    # 生成 IPTV 配置站点
    sites = []

    # 添加 EPG 配置
    for group_name, group_channels in groups.items():
        # 构建频道列表字符串
        channel_lines = []
        for ch in group_channels:
            channel_lines.append(f"{ch.get('title', ch.get('name', ''))}$#{ch.get('url', '')}")

        # 创建站点配置
        site = {
            "key": f"iptv_{group_name}",
            "name": f"IPTV-{group_name}",
            "type": 0,
            "api": "csp_IPTV",
            "ext": {
                "flag": [
                    "flv",
                    "mp4",
                    "m3u8"
                ],
                "url": "data:text/plain;charset=utf-8," + "#EXTM3U\n" + "\n".join([f"#EXTINF:-1 tvg-name=\"{ch.get('name', ch.get('title', ''))}\" group-title=\"{group_name}\",{ch.get('title', ch.get('name', ''))}\n{ch.get('url', '')}" for ch in group_channels])
            }
        }
        sites.append(site)

    # 添加主要 IPTV 站点（包含所有频道）
    all_channels_str = "\n".join([f"#EXTINF:-1 tvg-name=\"{ch.get('name', ch.get('title', ''))}\" group-title=\"{ch.get('group', '未分类')}\",{ch.get('title', ch.get('name', ''))}\n{ch.get('url', '')}" for ch in channels])

    main_site = {
        "key": "iptv_all",
        "name": "爱快IPTV",
        "type": 0,
        "api": "csp_IPTV",
        "ext": {
            "flag": [
                "flv",
                "mp4",
                "m3u8"
            ],
            "url": "data:text/plain;charset=utf-8," + "#EXTM3U\n" + all_channels_str
        },
        "epg": epg_url
    }

    # 将主站点插入到最前面
    sites.insert(0, main_site)

    # 构建完整配置
    config = {
        "sites": sites,
        "wallpaper": "https://ghproxy.com/https://raw.githubusercontent.com/zhanhong1998/Magic/master/wallpaper/wallpaper.json",
        "spider": "https://ghproxy.com/https://raw.githubusercontent.com/zhanhong1998/Magic/master/spider.jar",
        "lives": [
            {
                "group": "爱快IPTV",
                "channels": [
                    {
                        "name": ch.get('title', ch.get('name', '')),
                        "urls": [
                            f"{ch.get('name', ch.get('title', ''))}$#{ch.get('url', '')}"
                        ]
                    }
                    for ch in channels
                ]
            }
        ]
    }

    return config


def main():
    # 文件路径
    m3u_file = Path(__file__).parent / 'iptv_all_for_ikuai.m3u'
    output_file = Path(__file__).parent / 'ikuai_iptv_cn_tvbox.json'

    # EPG 源
    epg_url = "https://iptv.cola2high.tk/epg/epg_pw.xml"

    # 解析 M3U 文件
    print(f"正在解析 M3U 文件: {m3u_file}")
    channels = parse_m3u(m3u_file)
    print(f"共找到 {len(channels)} 个频道")

    # 构建配置
    print(f"正在构建 TVBox 配置...")
    config = build_tvbox_config(channels, epg_url)

    # 保存配置
    print(f"正在保存配置到: {output_file}")
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(config, f, ensure_ascii=False, indent=2)

    print(f"✓ 配置已成功生成!")
    print(f"  - 频道数量: {len(channels)}")
    print(f"  - 站点数量: {len(config['sites'])}")
    print(f"  - EPG 源: {epg_url}")


if __name__ == '__main__':
    main()
